#!/usr/bin/env python3
"""Create a NEW persistent WorkLog code-signing identity for GitHub Actions.

Requires an authenticated gh CLI and OpenSSL 3. No existing private keys or
Keychain items are read. Newly generated private material stays in memory and
subprocess stdin; only the public certificate is saved to disk and committed.

The PKCS#12 is encrypted at rest by GitHub Actions Secrets. Its fixed public
transport password avoids macOS/OpenSSL empty-password interoperability issues;
the password itself does not provide confidentiality.
Its 3DES/SHA-1 container encoding supports macOS security import; the RSA 3072
certificate itself is signed with SHA-256. This self-signed identity supplies
continuity across updates, not Apple Developer ID or notarization.
"""
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPOSITORY = 'RunaticMoon/worktrail'
SECRET_NAME = 'WORKLOG_CODESIGN_P12'
PUBLIC_FILE = Path(__file__).resolve().with_name('code-signing-cert.pem')
IDENTITY_NAME = 'WorkLog Persistent Code Signing'
PKCS12_PASSWORD = 'worklog-ci-container'


def command(*args, input=None):
    try:
        result = subprocess.run(args, input=input, capture_output=True)
    except OSError:
        raise RuntimeError('Unable to run command: ' + args[0]) from None
    if result.returncode:
        # Neither tool diagnostics nor stdin may be included in an error.
        raise RuntimeError('Command failed: ' + args[0])
    return result.stdout


def generate_identity():
    if not command('openssl', 'version').startswith(b'OpenSSL 3.'):
        raise RuntimeError('OpenSSL 3 is required to create the signing identity.')
    private_key = command('openssl', 'genpkey', '-algorithm', 'RSA',
                          '-pkeyopt', 'rsa_keygen_bits:3072')
    certificate = command(
        'openssl', 'req', '-new', '-x509', '-key', '/dev/stdin',
        '-sha256', '-days', '36525', '-subj', '/CN=' + IDENTITY_NAME + '/O=WorkLog',
        '-addext', 'basicConstraints=critical,CA:FALSE',
        '-addext', 'keyUsage=critical,digitalSignature',
        '-addext', 'extendedKeyUsage=critical,codeSigning', input=private_key,
    )
    # OpenSSL needs separate certificate and private-key inputs for PKCS#12.
    # The temporary file contains only the public certificate.
    with tempfile.TemporaryDirectory(prefix='worklog-public-cert-') as directory:
        public_path = Path(directory) / 'certificate.pem'
        public_path.write_bytes(certificate)
        pkcs12 = command(
            'openssl', 'pkcs12', '-export', '-inkey', '/dev/stdin',
            '-in', str(public_path), '-name', IDENTITY_NAME,
            '-passout', 'pass:' + PKCS12_PASSWORD,
            '-certpbe', 'PBE-SHA1-3DES', '-keypbe', 'PBE-SHA1-3DES',
            '-macalg', 'sha1', input=private_key,
        )
    return certificate, pkcs12


def provision():
    if PUBLIC_FILE.exists() or PUBLIC_FILE.is_symlink():
        raise RuntimeError('Public certificate already exists. Refusing automatic key rotation.')
    try:
        names = json.loads(command('gh', 'secret', 'list', '--repo', REPOSITORY, '--json', 'name'))
        if not isinstance(names, list) or any(not isinstance(item, dict) or
                                              not isinstance(item.get('name'), str) for item in names):
            raise ValueError()
    except ValueError:
        raise RuntimeError('Unable to validate existing GitHub secret names.') from None
    if any(item['name'] == SECRET_NAME for item in names):
        raise RuntimeError('Code-signing secret already exists. Refusing to overwrite it.')
    certificate, pkcs12 = generate_identity()
    # Reserve the public file before uploading so concurrent invocations in the
    # same checkout cannot replace one another's newly registered identity.
    with PUBLIC_FILE.open('xb') as public_file:
        public_file.write(certificate)
    try:
        command('gh', 'secret', 'set', SECRET_NAME, '--repo', REPOSITORY,
                input=base64.b64encode(pkcs12))
    except RuntimeError:
        PUBLIC_FILE.unlink()
        raise
    print('Persistent code-signing secret registered; public certificate saved to ' + str(PUBLIC_FILE))


if __name__ == '__main__':
    try:
        provision()
    except (RuntimeError, OSError, ValueError) as error:
        sys.exit(str(error))
