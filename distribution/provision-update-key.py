#!/usr/bin/env python3
"""Create a NEW dedicated Sparkle key and store it directly in GitHub Actions.

Existing credentials and Keychain items are never read. The private key exists
only in process memory and gh's stdin; only its public half is written to disk.
Requires an already authenticated gh CLI and OpenSSL with Ed25519 support.
"""
import base64
import json
import subprocess
import sys
from pathlib import Path

REPOSITORY = 'RunaticMoon/worktrail'
SECRET_NAME = 'WORKLOG_SPARKLE_PRIVATE_KEY'
PUBLIC_FILE = Path(__file__).resolve().with_name('sparkle-public-key.txt')


def command(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True)
    if result.returncode:
        # Avoid echoing input or tool diagnostics which could contain key material.
        raise RuntimeError('Command failed: ' + args[0])
    return result.stdout


def provision():
    if PUBLIC_FILE.exists():
        raise RuntimeError('Public key already exists. Refusing automatic key rotation.')
    names = json.loads(command('gh', 'secret', 'list', '--repo', REPOSITORY, '--json', 'name'))
    if any(item['name'] == SECRET_NAME for item in names):
        raise RuntimeError('Update signing secret already exists. Refusing to overwrite it.')
    private_der = command('openssl', 'genpkey', '-algorithm', 'ED25519', '-outform', 'DER')
    public_der = command('openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER', input=private_der)
    if len(private_der) != 48 or private_der[:16].hex() != '302e020100300506032b657004220420':
        raise RuntimeError('Unexpected Ed25519 private key encoding')
    if len(public_der) != 44 or public_der[:12].hex() != '302a300506032b6570032100':
        raise RuntimeError('Unexpected Ed25519 public key encoding')
    # Sparkle 2.10 common_cli/Secret.swift: newly generated keys store only the seed.
    secret = base64.b64encode(private_der[-32:])
    command('gh', 'secret', 'set', SECRET_NAME, '--repo', REPOSITORY, input=secret)
    PUBLIC_FILE.write_text(base64.b64encode(public_der[-32:]).decode('ascii') + '\n')
    print('Dedicated update signing secret registered; public key saved to ' + str(PUBLIC_FILE))


if __name__ == '__main__':
    try:
        provision()
    except (RuntimeError, OSError, ValueError) as error:
        sys.exit(str(error))
