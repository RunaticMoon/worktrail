"""Persistent signing identity provisioning; gh is always mocked."""
import base64
from datetime import datetime
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'code_signing_provision',
    Path(__file__).resolve().parents[1] / 'provision-code-signing-key.py',
)
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.public_file = Path(self.temp.name) / 'code-signing-cert.pem'
        patcher = patch.object(provision, 'PUBLIC_FILE', self.public_file)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_existing_public_certificate_refuses_all_commands(self):
        self.public_file.write_bytes(b'existing public certificate')
        with patch.object(provision, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'Refusing automatic key rotation'):
                provision.provision()
        command.assert_not_called()
        self.assertEqual(self.public_file.read_bytes(), b'existing public certificate')

    def test_dangling_public_symlink_refuses_all_commands(self):
        self.public_file.symlink_to(Path(self.temp.name) / 'missing')
        with patch.object(provision, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'Refusing automatic key rotation'):
                provision.provision()
        command.assert_not_called()

    def test_existing_github_secret_is_not_rotated(self):
        names = json.dumps([{'name': provision.SECRET_NAME}]).encode()
        with patch.object(provision, 'command', return_value=names) as command:
            with patch.object(provision, 'generate_identity') as generate:
                with self.assertRaisesRegex(RuntimeError, 'Refusing to overwrite'):
                    provision.provision()
        command.assert_called_once_with('gh', 'secret', 'list', '--repo', provision.REPOSITORY,
                                        '--json', 'name')
        generate.assert_not_called()
        self.assertFalse(self.public_file.exists())

    def test_registers_one_secret_and_writes_only_public_certificate(self):
        certificate, pkcs12 = b'fake public certificate', b'fake private PKCS12'
        output = io.StringIO()

        def fake_command(*args, input=None):
            if args[2] == 'list':
                return b'[]'
            self.assertEqual(self.public_file.read_bytes(), certificate)
            return b''

        with patch.object(provision, 'command', side_effect=fake_command) as command:
            with patch.object(provision, 'generate_identity', return_value=(certificate, pkcs12)):
                with redirect_stdout(output):
                    provision.provision()
        self.assertEqual(command.call_count, 2)
        command.assert_called_with('gh', 'secret', 'set', provision.SECRET_NAME,
                                   '--repo', provision.REPOSITORY, input=base64.b64encode(pkcs12))
        self.assertEqual(self.public_file.read_bytes(), certificate)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [self.public_file])
        self.assertNotIn(pkcs12.decode(), output.getvalue())
        self.assertNotIn(base64.b64encode(pkcs12).decode(), output.getvalue())

    def test_concurrently_created_certificate_prevents_secret_upload(self):
        def fake_generate():
            self.public_file.write_bytes(b'other invocation public certificate')
            return b'fake public certificate', b'fake private PKCS12'

        with patch.object(provision, 'command', return_value=b'[]') as command:
            with patch.object(provision, 'generate_identity', side_effect=fake_generate):
                with self.assertRaises(FileExistsError):
                    provision.provision()
        command.assert_called_once_with('gh', 'secret', 'list', '--repo', provision.REPOSITORY,
                                        '--json', 'name')
        self.assertEqual(self.public_file.read_bytes(), b'other invocation public certificate')

    def test_failed_secret_registration_does_not_save_certificate_or_print_private_material(self):
        certificate, pkcs12 = b'fake public certificate', b'fake private PKCS12'
        output = io.StringIO()
        with patch.object(provision, 'command', side_effect=[b'[]', RuntimeError('Command failed: gh')]):
            with patch.object(provision, 'generate_identity', return_value=(certificate, pkcs12)):
                with redirect_stdout(output):
                    with self.assertRaisesRegex(RuntimeError, 'Command failed: gh'):
                        provision.provision()
        self.assertFalse(self.public_file.exists())
        self.assertEqual(output.getvalue(), '')

    def test_malformed_secret_list_fails_closed_without_echoing_output(self):
        for invalid in (b'fake private data', b'{"private": "fake private data"}',
                        b'[{"name": 4}]', b'["fake private data"]'):
            with self.subTest(response=invalid):
                with patch.object(provision, 'command', return_value=invalid):
                    with patch.object(provision, 'generate_identity') as generate:
                        with self.assertRaisesRegex(RuntimeError, '^Unable to validate existing GitHub secret names.$'):
                            provision.provision()
                generate.assert_not_called()


class CommandTests(unittest.TestCase):
    def test_nonzero_exit_never_echoes_stdin_stdout_or_stderr(self):
        secret = b'fake private material'
        result = subprocess.CompletedProcess(['openssl'], 1, secret, secret)
        with patch.object(provision.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, '^Command failed: openssl$'):
                provision.command('openssl', 'pkcs12', input=secret)

    def test_os_error_is_sanitized(self):
        with patch.object(provision.subprocess, 'run', side_effect=OSError('fake private material')):
            with self.assertRaisesRegex(RuntimeError, '^Unable to run command: openssl$'):
                provision.command('openssl', 'version')

    def test_old_openssl_is_rejected_before_generation(self):
        for version in (b'LibreSSL 3.3.6', b'OpenSSL 1.1.1w'):
            with self.subTest(version=version):
                with patch.object(provision, 'command', return_value=version) as command:
                    with self.assertRaisesRegex(RuntimeError, 'OpenSSL 3 is required'):
                        provision.generate_identity()
                command.assert_called_once_with('openssl', 'version')


def openssl3_available():
    if not shutil.which('openssl'):
        return False
    result = subprocess.run(['openssl', 'version'], capture_output=True)
    return result.returncode == 0 and result.stdout.startswith(b'OpenSSL 3.')


@unittest.skipUnless(openssl3_available(), 'OpenSSL 3 is required for a real identity round trip')
class IdentityRoundTripTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Fresh test material only; no gh or existing Keychain/credential access.
        cls.certificate, cls.pkcs12 = provision.generate_identity()

    def test_certificate_has_persistent_code_signing_constraints(self):
        detail = provision.command('openssl', 'x509', '-noout', '-text', input=self.certificate).decode()
        self.assertIn('Public-Key: (3072 bit)', detail)
        self.assertIn('Signature Algorithm: sha256WithRSAEncryption', detail)
        self.assertIn('X509v3 Basic Constraints: critical\n                CA:FALSE', detail)
        self.assertIn('X509v3 Key Usage: critical\n                Digital Signature', detail)
        self.assertIn('X509v3 Extended Key Usage: critical\n                Code Signing', detail)
        dates = provision.command('openssl', 'x509', '-noout', '-dates', input=self.certificate).decode()
        start, end = [datetime.strptime(line.split('=', 1)[1], '%b %d %H:%M:%S %Y %Z')
                      for line in dates.splitlines()]
        self.assertEqual((end - start).days, 36525)

    def test_transport_password_pkcs12_round_trip_preserves_certificate_and_private_key(self):
        extracted_certificate = provision.command('openssl', 'pkcs12', '-passin',
                                                   'pass:' + provision.PKCS12_PASSWORD,
                                                   '-nokeys', input=self.pkcs12)
        original_der = provision.command('openssl', 'x509', '-outform', 'DER', input=self.certificate)
        extracted_der = provision.command('openssl', 'x509', '-outform', 'DER', input=extracted_certificate)
        self.assertEqual(original_der, extracted_der)
        extracted_private = provision.command('openssl', 'pkcs12', '-passin',
                                               'pass:' + provision.PKCS12_PASSWORD,
                                               '-nocerts', '-nodes', input=self.pkcs12)
        key_public = provision.command('openssl', 'pkey', '-pubout', input=extracted_private)
        cert_public = provision.command('openssl', 'x509', '-pubkey', '-noout', input=self.certificate)
        self.assertEqual(key_public, cert_public)

    def test_pkcs12_uses_macos_import_compatible_container(self):
        result = subprocess.run(['openssl', 'pkcs12', '-passin',
                                 'pass:' + provision.PKCS12_PASSWORD, '-info', '-noout'],
                                input=self.pkcs12, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'MAC: sha1,', result.stderr)
        self.assertIn(b'PKCS7 Encrypted data: pbeWithSHA1And3-KeyTripleDES-CBC', result.stderr)
        self.assertIn(b'Shrouded Keybag: pbeWithSHA1And3-KeyTripleDES-CBC', result.stderr)


if __name__ == '__main__':
    unittest.main()
