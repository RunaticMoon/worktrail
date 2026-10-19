"""Persistent release identity checks; all key material is newly generated or fake.

Linux runs the isolated orchestration tests. Disposable macOS GitHub runners
also sign distinct executables, without reading the login Keychain.
"""
import base64
import hashlib
import importlib.util
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


DISTRIBUTION = Path(__file__).resolve().parents[1]


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, DISTRIBUTION / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load_script('worklog_code_signing', 'code_signing.py')
provision = load_script('worklog_code_signing_provision_fixture', 'provision-code-signing-key.py')


# File-based Keychain routing follows Apple's TN3137: additions explicitly name
# kSecUseKeychain, and queries are limited to kSecMatchSearchList. Neither API
# below can fall back to the login/default keychain.
# https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
KEYCHAIN_FIXTURE_SOURCE = r'''
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static volatile const int fixture_version = FIXTURE_VERSION;
static const unsigned char fake_value[] = "WorkLog fake integration fixture";

static int access_fixture(const char *operation, const char *keychain_path) {
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(keychain_path, &keychain);
    if (status != errSecSuccess) {
        fprintf(stderr, "Keychain fixture open status=%d\n", (int)status);
        return 10;
    }
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR("dev.worklog.test.signing-continuity"));
    CFDictionarySetValue(query, kSecAttrAccount, CFSTR("fake-test-account"));
    CFDataRef expected = CFDataCreate(NULL, fake_value, sizeof(fake_value) - 1);
    int result = 0;
    if (strcmp(operation, "create") == 0) {
        CFDictionarySetValue(query, kSecUseKeychain, keychain);
        CFDictionarySetValue(query, kSecValueData, expected);
        status = SecItemAdd(query, NULL);
        if (status != errSecSuccess) result = 11;
    } else {
        const void *keychains[] = { keychain };
        CFArrayRef search_list = CFArrayCreate(NULL, keychains, 1, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(query, kSecMatchSearchList, search_list);
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
        CFTypeRef stored = NULL;
        status = SecItemCopyMatching(query, &stored);
        if (status != errSecSuccess) {
            result = 12;
        } else if (!stored || CFGetTypeID(stored) != CFDataGetTypeID() || !CFEqual(stored, expected)) {
            result = 13;
        }
        if (stored) CFRelease(stored);
        CFRelease(search_list);
    }
    // Only status codes are printed, never Keychain data.
    if (result) fprintf(stderr, "Keychain fixture %s status=%d\n", operation, (int)status);
    CFRelease(expected);
    CFRelease(query);
    CFRelease(keychain);
    return result;
}

int main(int argc, const char *argv[]) {
    if (argc != 3 || fixture_version < 1 ||
        (strcmp(argv[1], "create") != 0 && strcmp(argv[1], "read") != 0)) return 2;
    Boolean previously_allowed = true;
    if (SecKeychainGetUserInteractionAllowed(&previously_allowed) != errSecSuccess) return 3;
    // An ACL prompt is a test failure, not a modal dialog that can hang CI.
    if (SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) return 4;
    int result = access_fixture(argv[1], argv[2]);
    if (SecKeychainSetUserInteractionAllowed(previously_allowed) != errSecSuccess && result == 0) return 5;
    return result;
}
'''


def make_app(root, name='WorkLog', bundle_id=signing.BUNDLE_ID, version=1):
    app = Path(root) / (name + '.app')
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump({
            'CFBundleIdentifier': bundle_id,
            'CFBundleExecutable': 'WorkLog',
            'CFBundlePackageType': 'APPL',
            'CFBundleVersion': str(version),
            'CFBundleShortVersionString': '1.0.' + str(version),
        }, stream)
    return app


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='worklog-signing-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = make_app(self.root)
        self.der = b'fake public signing certificate'
        self.p12 = b'fake disposable signing identity'
        self.encoded = base64.b64encode(self.p12).decode('ascii')
        self.certificate = self.root / 'public.pem'
        self.platform = mock.patch.object(signing.sys, 'platform', 'darwin')
        self.platform.start()
        self.addCleanup(self.platform.stop)
        runner = mock.patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_ACTIONS': 'true'})
        runner.start()
        self.addCleanup(runner.stop)
        self.cert_patch = mock.patch.object(signing, 'certificate_der', return_value=self.der)
        self.cert_patch.start()
        self.addCleanup(self.cert_patch.stop)

    def test_requirement_pins_certificate_and_bundle_id_without_binary_hash(self):
        expected = ('identifier "dev.worklog.WorkLog" and certificate leaf = H"' +
                    hashlib.sha1(self.der).hexdigest() + '"')
        self.assertEqual(signing.requirement(self.certificate), expected)
        self.assertEqual(signing.requirement(self.root / 'other-location.pem'), expected)

    def test_missing_or_invalid_identity_stops_before_any_keychain_operation(self):
        for encoded in ('', 'not base64!', 'YW Jj', '\uD55C\uAE00'):
            with self.subTest(encoded=encoded):
                with mock.patch.dict(os.environ, {signing.SECRET_NAME: encoded}):
                    with mock.patch.object(signing, 'command') as command:
                        with self.assertRaisesRegex(RuntimeError, 'identity is missing or invalid'):
                            signing.sign(self.app, self.certificate)
                    command.assert_not_called()

    def test_wrong_bundle_identifier_stops_before_any_keychain_operation(self):
        app = make_app(self.root, name='Other', bundle_id='dev.other.App')
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command') as command:
                with self.assertRaisesRegex(RuntimeError, 'unexpected app bundle identifier'):
                    signing.sign(app, self.certificate)
            command.assert_not_called()

    def test_signing_refuses_to_modify_search_list_outside_disposable_runners(self):
        for runner, github_actions in (('self-hosted', 'true'), ('', 'true'),
                                       ('github-hosted', 'false'), ('github-hosted', '')):
            with self.subTest(runner=runner, github_actions=github_actions):
                with mock.patch.dict(os.environ, {'RUNNER_ENVIRONMENT': runner,
                                                  'GITHUB_ACTIONS': github_actions}):
                    with mock.patch.object(signing, 'command') as command:
                        with self.assertRaisesRegex(RuntimeError, 'disposable GitHub-hosted runner'):
                            signing.sign(self.app, self.certificate)
                    command.assert_not_called()

    def test_malformed_pkcs12_stops_before_any_keychain_operation(self):
        # Real OpenSSL parses fake bytes; no macOS command may be reached.
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command', wraps=signing.command) as command:
                with self.assertRaisesRegex(RuntimeError, 'Code signing command failed: openssl'):
                    signing.sign(self.app, self.certificate)
        self.assertTrue(command.call_args_list)
        self.assertTrue(all(call.args[0] == 'openssl' for call in command.call_args_list))

    def test_identity_certificate_mismatch_stops_before_any_keychain_operation(self):
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command', return_value=b'other public certificate') as command:
                with self.assertRaisesRegex(RuntimeError, 'identity differs from the pinned certificate'):
                    signing.sign(self.app, self.certificate)
        self.assertTrue(command.call_args_list)
        self.assertTrue(all(call.args[0] == 'openssl' for call in command.call_args_list))

    def mock_signing_commands(self, intercept=None):
        previous = ['/Users/fake/Library/Keychains/login.keychain-db',
                    '/tmp/another fake.keychain-db']
        state = {'previous': previous, 'search_list': previous.copy(),
                 'keychain': None, 'private': None, 'deleted': False, 'snapshots': 0}

        def run(*args, **kwargs):
            self.assertNotIn(signing.SECRET_NAME, os.environ)
            self.assertNotIn('/usr/bin/sudo', args)
            self.assertNotIn('add-trusted-cert', args)
            self.assertNotIn('remove-trusted-cert', args)
            if intercept is not None:
                intercept(state, args)
            if args[:2] == ('openssl', 'pkcs12'):
                self.assertEqual(kwargs['input'], self.p12)
                self.assertIn('-nokeys', args)
                return b'fake public PEM'
            if args[:2] == ('openssl', 'x509'):
                return self.der
            if args[:2] == ('/usr/bin/security', 'list-keychains'):
                self.assertEqual(args[2:4], ('-d', 'user'))
                if '-s' in args:
                    state['search_list'] = list(args[5:])
                else:
                    state['snapshots'] += 1
                    return ''.join('    "' + path + '"\n' for path in state['search_list']).encode()
            if args[:2] == ('/usr/bin/security', 'create-keychain'):
                self.assertGreater(state['snapshots'], 0, 'snapshot must precede keychain creation')
                state['keychain'] = Path(args[-1])
                # Keychain creation can change the default search list itself.
                state['search_list'].append(str(state['keychain']))
                state['private'] = state['keychain'].with_name('identity.p12')
                self.assertEqual(state['private'].read_bytes(), self.p12)
                self.assertEqual(stat.S_IMODE(state['private'].stat().st_mode), 0o600)
            if args[0] == '/usr/bin/codesign':
                self.assertEqual(state['search_list'], [str(state['keychain'])])
                self.assertEqual(args[args.index('--keychain') + 1], str(state['keychain']))
                self.assertFalse(state['private'].exists())
            if args[:2] == ('/usr/bin/security', 'delete-keychain'):
                self.assertEqual(args[-1], str(state['keychain']))
                state['deleted'] = True
            return b''

        return state, run

    def test_signing_failure_restores_search_list_and_removes_temporary_material(self):
        for failure in ('import', 'restrict', 'codesign', 'codesign timeout'):
            with self.subTest(failure=failure):
                def fail(state, args):
                    at_import = args[:2] == ('/usr/bin/security', 'import')
                    at_restrict = (args[:5] == ('/usr/bin/security', 'list-keychains', '-d', 'user', '-s')
                                   and list(args[5:]) != state['previous'])
                    at_codesign = args[0] == '/usr/bin/codesign'
                    if ((failure == 'import' and at_import) or
                        (failure == 'restrict' and at_restrict) or
                        (failure.startswith('codesign') and at_codesign)):
                        raise RuntimeError('simulated ' + failure)

                state, run = self.mock_signing_commands(fail)
                with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
                    with mock.patch.object(signing, 'command', side_effect=run) as command:
                        with mock.patch.object(signing, 'verify') as verify:
                            with self.assertRaisesRegex(RuntimeError, 'simulated ' + failure):
                                signing.sign(self.app, self.certificate)
                verify.assert_not_called()
                self.assertEqual(state['search_list'], state['previous'])
                self.assertEqual(state['snapshots'], 2)
                self.assertTrue(state['deleted'])
                self.assertEqual(command.call_args.args,
                                 ('/usr/bin/security', 'delete-keychain', str(state['keychain'])))
                self.assertFalse(state['keychain'].parent.exists())
                self.assertFalse(state['private'].exists())

    def test_restore_failure_still_deletes_temporary_keychain_and_skips_verification(self):
        for failure in ('failed', 'timed out'):
            with self.subTest(failure=failure):
                def fail(state, args):
                    if (args[:5] == ('/usr/bin/security', 'list-keychains', '-d', 'user', '-s')
                            and list(args[5:]) == state['previous']):
                        raise RuntimeError('simulated search list restore ' + failure)

                state, run = self.mock_signing_commands(fail)
                with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
                    with mock.patch.object(signing, 'command', side_effect=run):
                        with mock.patch.object(signing, 'verify') as verify:
                            with self.assertRaisesRegex(RuntimeError, 'simulated search list restore ' + failure):
                                signing.sign(self.app, self.certificate)
                verify.assert_not_called()
                self.assertTrue(state['deleted'])
                self.assertFalse(state['keychain'].parent.exists())

    def test_restore_readback_mismatch_fails_even_when_security_reports_success(self):
        state, run = self.mock_signing_commands()
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command', side_effect=run):
                with mock.patch.object(signing, 'keychain_search_list',
                                       side_effect=[state['previous'], ['/tmp/unexpected.keychain-db']]):
                    # The helper is mocked, so mark the initial snapshot for the
                    # separate command fixture's creation-order assertion.
                    state['snapshots'] = 1
                    with mock.patch.object(signing, 'verify') as verify:
                        with self.assertRaisesRegex(RuntimeError, 'search list was not restored'):
                            signing.sign(self.app, self.certificate)
        verify.assert_not_called()
        self.assertTrue(state['deleted'])
        self.assertFalse(state['keychain'].parent.exists())

    def test_verification_runs_only_after_search_list_and_temporary_keychain_are_restored(self):
        state, run = self.mock_signing_commands()

        def verify(app, certificate):
            self.assertEqual(state['search_list'], state['previous'])
            self.assertEqual(state['snapshots'], 2)
            self.assertTrue(state['deleted'])
            self.assertFalse(state['keychain'].parent.exists())

        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command', side_effect=run):
                with mock.patch.object(signing, 'verify', side_effect=verify) as verification:
                    signing.sign(self.app, self.certificate)
        verification.assert_called_once_with(self.app.resolve(), self.certificate)

    def test_unsafe_search_list_snapshot_stops_before_keychain_creation(self):
        def run(*args, **kwargs):
            if args[:2] == ('openssl', 'x509'):
                return self.der
            if args[:2] == ('/usr/bin/security', 'list-keychains'):
                self.assertNotIn('-s', args)
                return b'"/tmp/unterminated.keychain-db'
            self.assertEqual(args[:2], ('openssl', 'pkcs12'))
            return b'fake public PEM'

        with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
            with mock.patch.object(signing, 'command', side_effect=run):
                with mock.patch.object(signing, 'verify') as verify:
                    with self.assertRaisesRegex(RuntimeError, 'parse the keychain search list'):
                        signing.sign(self.app, self.certificate)
        verify.assert_not_called()

    def verify_with(self, designated, extracted):
        def run(*args, **kwargs):
            if '--requirements' in args:
                return designated.encode('utf-8')
            if any(arg.startswith('--extract-certificates=') for arg in args):
                prefix = next(arg.split('=', 1)[1] for arg in args
                              if arg.startswith('--extract-certificates='))
                Path(prefix + '0').write_bytes(extracted)
            return b''

        return mock.patch.object(signing, 'command', side_effect=run)

    def test_verify_checks_pinned_requirement_and_complete_certificate(self):
        expected = signing.requirement(self.certificate)
        with self.verify_with('designated => ' + expected + '\n', self.der) as command:
            signing.verify(self.app, self.certificate)
        self.assertEqual(command.call_args_list[0].args,
                         ('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R',
                          '=' + expected, str(self.app)))

    def test_verify_rejects_replaced_or_version_bound_designated_requirement(self):
        expected = signing.requirement(self.certificate)
        for designated in ('', 'designated => identifier "dev.worklog.WorkLog"\n',
                           'designated => ' + expected + ' and cdhash H"' + 'a' * 40 + '"\n',
                           ('designated => ' + expected + '\n') * 2):
            with self.subTest(designated=designated):
                with self.verify_with(designated, self.der):
                    with self.assertRaisesRegex(RuntimeError, 'version-independent designated requirement'):
                        signing.verify(self.app, self.certificate)

    def test_verify_rejects_different_embedded_public_certificate(self):
        expected = signing.requirement(self.certificate)
        with self.verify_with('designated => ' + expected + '\n', b'other public signer'):
            with self.assertRaisesRegex(RuntimeError, 'signer differs from the pinned certificate'):
                signing.verify(self.app, self.certificate)


class KeychainSearchListTests(unittest.TestCase):
    def test_paths_with_spaces_are_preserved_in_order_without_reading_keychain_contents(self):
        with mock.patch.object(signing, 'command', return_value=(
                b'    "/Users/fake/Library/Keychains/login.keychain-db"\n'
                b'    "/tmp/a fake keychain.keychain-db"\n')) as command:
            self.assertEqual(signing.keychain_search_list(), [
                '/Users/fake/Library/Keychains/login.keychain-db', '/tmp/a fake keychain.keychain-db'])
        command.assert_called_once_with('/usr/bin/security', 'list-keychains', '-d', 'user')

    def test_empty_search_list_can_be_restored(self):
        with mock.patch.object(signing, 'command', return_value=b'\n'):
            self.assertEqual(signing.keychain_search_list(), [])

    def test_invalid_path_listing_is_rejected_without_mutation(self):
        for listing in (b'"/tmp/unclosed', b'"relative.keychain-db"', b'""',
                        b'"/tmp/null\x00.keychain-db"', b'"/tmp/new\nline.keychain-db"', b'\xff'):
            with self.subTest(listing=listing):
                with mock.patch.object(signing, 'command', return_value=listing) as command:
                    with self.assertRaisesRegex(RuntimeError, 'parse the keychain search list'):
                        signing.keychain_search_list()
                command.assert_called_once_with('/usr/bin/security', 'list-keychains', '-d', 'user')


class ProcessIsolationTests(unittest.TestCase):
    def test_commands_never_inherit_signing_secret_or_expose_failed_diagnostics(self):
        secret = 'FAKE-SECRET-MUST-NOT-APPEAR'
        for returncode in (0, 1):
            with self.subTest(returncode=returncode):
                result = subprocess.CompletedProcess(['fake-tool'], returncode,
                                                     stdout=b'public result', stderr=secret.encode())
                with mock.patch.dict(os.environ, {signing.SECRET_NAME: secret, 'WORKLOG_TEST': 'visible'}):
                    with mock.patch.object(signing.subprocess, 'run', return_value=result) as run:
                        if returncode:
                            with self.assertRaises(RuntimeError) as raised:
                                signing.command('/fake/fake-tool')
                            self.assertNotIn(secret, str(raised.exception))
                        else:
                            self.assertEqual(signing.command('/fake/fake-tool'), b'public result')
                self.assertNotIn(signing.SECRET_NAME, run.call_args.kwargs['env'])
                self.assertEqual(run.call_args.kwargs['env']['WORKLOG_TEST'], 'visible')

    def test_command_timeout_is_bounded_and_does_not_expose_arguments_or_output(self):
        secret = 'FAKE-CREDENTIAL-IN-ARGS-AND-OUTPUT'
        with mock.patch.object(signing.subprocess, 'run', side_effect=subprocess.TimeoutExpired(
                ['/fake/fake-tool', secret], 30, output=secret.encode(), stderr=secret.encode())) as run:
            with self.assertRaisesRegex(RuntimeError, '^Code signing command timed out: fake-tool$'):
                signing.command('/fake/fake-tool', secret)
        self.assertEqual(run.call_args.kwargs['timeout'], 30)

    def test_certificate_conversion_never_inherits_secret_or_exposes_failed_diagnostics(self):
        secret = 'FAKE-P12-NOT-FOR-OPENSSL-ENV'
        result = subprocess.CompletedProcess(['openssl'], 1, stdout=b'', stderr=secret.encode())
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: secret}):
            with mock.patch.object(signing.subprocess, 'run', return_value=result) as run:
                with self.assertRaises(RuntimeError) as raised:
                    signing.certificate_der(Path('fake-public.pem'))
        self.assertNotIn(signing.SECRET_NAME, run.call_args.kwargs['env'])
        self.assertNotIn(secret, str(raised.exception))


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
                     and os.environ.get('GITHUB_ACTIONS') == 'true',
                     'requires a disposable macOS GitHub-hosted runner')
class MacOSSigningContinuityTests(unittest.TestCase):
    def test_updated_binary_satisfies_previous_release_requirement_but_another_signer_does_not(self):
        # No existing identity, certificate, private key, or login Keychain is read.
        # Use the same fresh-generation helper as provisioning, never provision().
        with tempfile.TemporaryDirectory(prefix='worklog-signing-regression-') as temporary:
            root = Path(temporary)
            certificate, identity = provision.generate_identity()
            public = root / 'public.pem'
            public.write_bytes(certificate)
            first = make_app(root, name='First', version=1)
            second = make_app(root, name='Second', version=2)
            impostor = make_app(root, name='Impostor', version=3)
            for marker, app in enumerate((first, second, impostor), start=1):
                signing.command('/usr/bin/xcrun', 'clang', '-x', 'c', '-Wno-deprecated-declarations',
                                f'-DFIXTURE_VERSION={marker}', '-framework', 'Security',
                                '-framework', 'CoreFoundation', '-o',
                                str(app / 'Contents/MacOS/WorkLog'), '-',
                                input=KEYCHAIN_FIXTURE_SOURCE.encode())
            self.assertNotEqual((first / 'Contents/MacOS/WorkLog').read_bytes(),
                                (second / 'Contents/MacOS/WorkLog').read_bytes())

            for app in (first, second):
                with mock.patch.dict(os.environ, {signing.SECRET_NAME: base64.b64encode(identity).decode()}):
                    signing.sign(app, public)
                signing.verify(app, public)

            first_details = signing.command('/usr/bin/codesign', '--display', '--requirements', '-',
                                            str(first), include_stderr=True)
            first_requirement = next(line.removeprefix('designated => ')
                                     for line in first_details.decode().splitlines()
                                     if line.startswith('designated => '))
            signing.command('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + first_requirement, str(second))

            other_certificate, other_identity = provision.generate_identity()
            other_public = root / 'other-public.pem'
            other_public.write_bytes(other_certificate)
            with mock.patch.dict(os.environ, {signing.SECRET_NAME: base64.b64encode(other_identity).decode()}):
                signing.sign(impostor, other_public)
            with self.assertRaises(RuntimeError):
                signing.command('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + first_requirement, str(impostor))
            with self.assertRaises(RuntimeError):
                signing.verify(impostor, public)

            # The item's ACL belongs to the first signed fixture. A subsequent
            # binary with the same identity must read it with UI disabled, while
            # a different signer must be refused. All item data is fixed and fake.
            keychain = root / 'fake-items.keychain-db'
            fixture_password = 'fake-test-keychain-password'
            signing.command('/usr/bin/security', 'create-keychain', '-p', fixture_password, str(keychain))
            try:
                signing.command('/usr/bin/security', 'set-keychain-settings', '-lut', '3600', str(keychain))
                signing.command('/usr/bin/security', 'unlock-keychain', '-p', fixture_password, str(keychain))

                def run_fixture(app, operation):
                    return subprocess.run(
                        [str(app / 'Contents/MacOS/WorkLog'), operation, str(keychain)],
                        capture_output=True, timeout=30,
                        env={key: value for key, value in os.environ.items() if key != signing.SECRET_NAME},
                    )

                for app, operation in ((first, 'create'), (first, 'read'), (second, 'read')):
                    result = run_fixture(app, operation)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                refused = run_fixture(impostor, 'read')
                self.assertEqual(refused.returncode, 12, refused.stderr.decode())
                self.assertIn(b'Keychain fixture read status=', refused.stderr)
                # A refused signer must not change the item or its authorized ACL.
                result = run_fixture(second, 'read')
                self.assertEqual(result.returncode, 0, result.stderr.decode())
            finally:
                signing.command('/usr/bin/security', 'delete-keychain', str(keychain))


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
                     and os.environ.get('GITHUB_ACTIONS') == 'true'
                     and os.environ.get('WORKLOG_SIGNING_SMOKE_APP'),
                     'requires a disposable macOS runner and WORKLOG_SIGNING_SMOKE_APP')
class MacOSPackagedAppSigningTests(unittest.TestCase):
    def test_packaged_app_loads_sparkle_after_persistent_identity_signing(self):
        source = Path(os.environ['WORKLOG_SIGNING_SMOKE_APP']).resolve()
        self.assertTrue((source / 'Contents/Frameworks/Sparkle.framework').is_dir())
        with tempfile.TemporaryDirectory(prefix='worklog-signed-package-test-') as temporary:
            root = Path(temporary)
            app = root / 'WorkLog.app'
            # ditto preserves the versioned framework's nested symlinks/signatures.
            signing.command('/usr/bin/ditto', str(source), str(app))
            certificate, identity = provision.generate_identity()
            public = root / 'public.pem'
            public.write_bytes(certificate)
            with mock.patch.dict(os.environ, {signing.SECRET_NAME: base64.b64encode(identity).decode()}):
                signing.sign(app, public)
            signing.verify(app, public)
            with (app / 'Contents/Info.plist').open('rb') as stream:
                executable = plistlib.load(stream)['CFBundleExecutable']
            self.assertEqual(Path(executable).name, executable)
            result = subprocess.run(
                [str(app / 'Contents/MacOS' / executable), '--updater-smoke-test'],
                capture_output=True, timeout=30,
                env={key: value for key, value in os.environ.items() if key != signing.SECRET_NAME},
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn(b'WorkLog Sparkle loader smoke test passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
