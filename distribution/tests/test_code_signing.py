"""Persistent release identity checks; all key material is newly generated or fake.

Linux runs the isolated orchestration tests. macOS additionally signs distinct
executables using disposable keychains, without reading the login Keychain.
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

    def test_signing_failure_removes_temporary_identity_and_keychain(self):
        for failure in ('import', 'codesign'):
            with self.subTest(failure=failure):
                keychains = []
                private_files = []

                def run(*args, **kwargs):
                    self.assertNotIn(signing.SECRET_NAME, os.environ)
                    if args[:2] == ('openssl', 'pkcs12'):
                        self.assertEqual(kwargs['input'], self.p12)
                        self.assertIn('-nokeys', args)
                        return b'fake public PEM'
                    if args[:2] == ('openssl', 'x509'):
                        return self.der
                    if args[:2] == ('/usr/bin/security', 'create-keychain'):
                        keychains.append(Path(args[-1]))
                    if args[:2] == ('/usr/bin/security', 'import'):
                        private = Path(args[2])
                        private_files.append(private)
                        self.assertEqual(private.read_bytes(), self.p12)
                        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
                        if failure == 'import':
                            raise RuntimeError('simulated import failure')
                    if args[0] == '/usr/bin/codesign':
                        self.assertFalse(private_files[0].exists())
                        self.assertIn('--keychain', args)
                        self.assertEqual(args[args.index('--keychain') + 1], str(keychains[0]))
                        raise RuntimeError('simulated codesign failure')
                    return b''

                with mock.patch.dict(os.environ, {signing.SECRET_NAME: self.encoded}):
                    with mock.patch.object(signing, 'command', side_effect=run) as command:
                        with self.assertRaisesRegex(RuntimeError, 'simulated ' + failure + ' failure'):
                            signing.sign(self.app, self.certificate)
                self.assertEqual(command.call_args.args,
                                 ('/usr/bin/security', 'delete-keychain', str(keychains[0])))
                self.assertFalse(keychains[0].parent.exists())
                self.assertTrue(private_files)
                self.assertFalse(private_files[0].exists())

    def verify_with(self, designated, extracted):
        def run(*args, **kwargs):
            if '--requirements' in args:
                return designated.encode('utf-8')
            if '--extract-certificates' in args:
                prefix = args[args.index('--extract-certificates') + 1]
                Path(prefix + '0').write_bytes(extracted)
            return b''

        return mock.patch.object(signing, 'command', side_effect=run)

    def test_verify_checks_pinned_requirement_and_complete_certificate(self):
        expected = signing.requirement(self.certificate)
        with self.verify_with('designated => ' + expected + '\n', self.der) as command:
            signing.verify(self.app, self.certificate)
        self.assertEqual(command.call_args_list[0].args,
                         ('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R',
                          expected, str(self.app)))

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

    def test_certificate_conversion_never_inherits_secret_or_exposes_failed_diagnostics(self):
        secret = 'FAKE-P12-NOT-FOR-OPENSSL-ENV'
        result = subprocess.CompletedProcess(['openssl'], 1, stdout=b'', stderr=secret.encode())
        with mock.patch.dict(os.environ, {signing.SECRET_NAME: secret}):
            with mock.patch.object(signing.subprocess, 'run', return_value=result) as run:
                with self.assertRaises(RuntimeError) as raised:
                    signing.certificate_der(Path('fake-public.pem'))
        self.assertNotIn(signing.SECRET_NAME, run.call_args.kwargs['env'])
        self.assertNotIn(secret, str(raised.exception))


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS codesign and disposable keychains')
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
                signing.command('/usr/bin/xcrun', 'clang', '-x', 'c', '-o',
                                str(app / 'Contents/MacOS/WorkLog'), '-',
                                input=f'int main(void) {{ return {marker}; }}\n'.encode())
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
            signing.command('/usr/bin/codesign', '--verify', '--strict', '-R', first_requirement, str(second))

            other_certificate, other_identity = provision.generate_identity()
            other_public = root / 'other-public.pem'
            other_public.write_bytes(other_certificate)
            with mock.patch.dict(os.environ, {signing.SECRET_NAME: base64.b64encode(other_identity).decode()}):
                signing.sign(impostor, other_public)
            with self.assertRaises(RuntimeError):
                signing.command('/usr/bin/codesign', '--verify', '--strict', '-R', first_requirement, str(impostor))
            with self.assertRaises(RuntimeError):
                signing.verify(impostor, public)


if __name__ == '__main__':
    unittest.main()
