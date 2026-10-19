#!/usr/bin/env python3
"""Sign releases with one persistent identity, without opening the login Keychain.

Only a disposable keychain containing the dedicated release identity is used.
Signing is restricted to disposable GitHub-hosted runners because codesign
requires temporarily restricting the user keychain search list to this keychain.
System certificate trust is never modified.
The committed public certificate pins both the signer and designated requirement.
Do not add hardened runtime/library validation: Sparkle has a different signer.
"""
import base64
import hashlib
import os
import plistlib
import secrets
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLE_ID = 'dev.worklog.WorkLog'
SECRET_NAME = 'WORKLOG_CODESIGN_P12'
PUBLIC_FILE = Path(__file__).resolve().with_name('code-signing-cert.pem')
# Public transport value, not a credential. macOS and OpenSSL disagree on an
# empty PKCS#12 password. Confidentiality comes from GitHub Secrets, not this.
PKCS12_PASSWORD = 'worklog-ci-container'


def command(*args, input=None, include_stderr=False):
    # Do not pass the signing secret to subprocesses or print their diagnostics.
    env = {key: value for key, value in os.environ.items() if key != SECRET_NAME}
    try:
        result = subprocess.run(args, input=input, capture_output=True, env=env, timeout=30)
    except subprocess.TimeoutExpired:
        raise RuntimeError('Code signing command timed out: ' + Path(args[0]).name) from None
    if result.returncode:
        raise RuntimeError('Code signing command failed: ' + Path(args[0]).name)
    return result.stdout + (result.stderr if include_stderr else b'')


def certificate_der(certificate):
    # OpenSSL output here is public DER, not a secret.
    result = subprocess.run(
        ['openssl', 'x509', '-in', str(certificate), '-outform', 'DER'],
        capture_output=True, timeout=30,
        env={key: value for key, value in os.environ.items() if key != SECRET_NAME},
    )
    if result.returncode or not result.stdout:
        raise RuntimeError('The pinned code signing certificate is missing or invalid')
    return result.stdout


def requirement(certificate):
    # Apple's requirement language identifies a certificate by its SHA-1 digest.
    # Verification also compares the complete embedded certificate below.
    fingerprint = hashlib.sha1(certificate_der(certificate)).hexdigest()
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint}"'


def verify(app, certificate=PUBLIC_FILE):
    expected = requirement(certificate)
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + expected, str(app))
    details = command('/usr/bin/codesign', '--display', '--requirements', '-', str(app),
                      include_stderr=True).decode()
    designated = [line.removeprefix('designated => ') for line in details.splitlines()
                  if line.startswith('designated => ')]
    if designated != [expected]:
        raise RuntimeError('The app must retain the pinned, version-independent designated requirement')
    with tempfile.TemporaryDirectory(prefix='worklog-cert-check-') as temporary:
        prefix = str(Path(temporary) / 'signer-')
        command('/usr/bin/codesign', '--display', '--extract-certificates=' + prefix, str(app))
        if Path(prefix + '0').read_bytes() != certificate_der(certificate):
            raise RuntimeError('The app signer differs from the pinned certificate')


def keychain_search_list():
    # Read paths only, never the contents of any pre-existing keychain.
    try:
        paths = shlex.split(command('/usr/bin/security', 'list-keychains', '-d', 'user').decode())
    except (UnicodeDecodeError, ValueError):
        raise RuntimeError('Unable to parse the keychain search list') from None
    if any(not Path(path).is_absolute() or '\x00' in path or '\n' in path for path in paths):
        raise RuntimeError('Unable to parse the keychain search list')
    return paths


def sign(app, certificate=PUBLIC_FILE):
    if sys.platform != 'darwin':
        raise RuntimeError('App code signing requires macOS')
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise RuntimeError('Signing requires a disposable GitHub-hosted runner')
    app = Path(app).resolve()
    with (app / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('CFBundleIdentifier') != BUNDLE_ID:
            raise RuntimeError('Refusing to sign an unexpected app bundle identifier')
    expected = requirement(certificate)
    encoded = os.environ.pop(SECRET_NAME, '')
    try:
        identity = base64.b64decode(encoded, validate=True)
        if not identity:
            raise ValueError()
    except ValueError:
        raise RuntimeError('The dedicated code signing identity is missing or invalid') from None
    # Reject malformed/mismatched input before creating even the temporary keychain.
    public_pem = command('openssl', 'pkcs12', '-passin', 'pass:' + PKCS12_PASSWORD, '-clcerts', '-nokeys',
                         input=identity)
    embedded = command('openssl', 'x509', '-outform', 'DER', input=public_pem)
    if embedded != certificate_der(certificate):
        raise RuntimeError('The signing identity differs from the pinned certificate')
    fingerprint = hashlib.sha1(certificate_der(certificate)).hexdigest()
    with tempfile.TemporaryDirectory(prefix='worklog-signing-') as temporary:
        directory = Path(temporary)
        p12 = directory / 'identity.p12'
        # No private material under the checkout, artifact directory, or user home.
        with p12.open('xb') as stream:
            os.chmod(p12, 0o600)
            stream.write(identity)
        keychain = str(directory / 'release.keychain-db')
        password = secrets.token_urlsafe(32)
        previous_keychains = keychain_search_list()
        try:
            command('/usr/bin/security', 'create-keychain', '-p', password, keychain)
            command('/usr/bin/security', 'set-keychain-settings', '-lut', '3600', keychain)
            command('/usr/bin/security', 'unlock-keychain', '-p', password, keychain)
            command('/usr/bin/security', 'import', str(p12), '-k', keychain,
                    '-P', PKCS12_PASSWORD, '-T', '/usr/bin/codesign')
            p12.unlink()
            command('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
                    '-s', '-k', password, keychain)
            # --keychain only RESTRICTS a search; it does not add the keychain
            # to the search list (Apple DTS forums/thread/728073). Exclude all
            # pre-existing keychains while resolving the dedicated identity.
            command('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', keychain)
            command('/usr/bin/codesign', '--force', '--sign', fingerprint,
                    '--keychain', keychain, '--timestamp=none',
                    '--requirements', '=designated => ' + expected, str(app))
        finally:
            try:
                command('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous_keychains)
                if keychain_search_list() != previous_keychains:
                    raise RuntimeError('The original keychain search list was not restored')
            finally:
                command('/usr/bin/security', 'delete-keychain', keychain)
    # This works without installing or trusting the certificate on any Mac.
    verify(app, certificate)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('sign', 'verify'):
        raise RuntimeError('Usage: code_signing.py sign|verify <WorkLog.app>')
    if sys.platform != 'darwin':
        raise RuntimeError('App code signing verification requires macOS')
    if sys.argv[1] == 'sign':
        sign(sys.argv[2])
    else:
        verify(sys.argv[2])
    print('Verified persistent WorkLog signing identity and designated requirement')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError):
        # Avoid printing subprocess arguments, input, or credential diagnostics.
        sys.exit('Code signing failed; check the dedicated identity and pinned public certificate')
