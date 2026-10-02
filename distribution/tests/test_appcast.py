"""Update feed trust boundaries: version, origin, archive and signature metadata."""
import base64
import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        (self.root / 'WorkLog-0.2.0-arm64.dmg').write_bytes(b'fake update archive')
        self.signature = base64.b64encode(bytes(64)).decode('ascii')
        release.appcast('v0.2.0', self.root, self.signature)

    def mutate(self, operation):
        path = self.root / 'appcast.xml'
        tree = ET.parse(path)
        operation(tree.find('./channel/item'))
        tree.write(path, encoding='utf-8', xml_declaration=True)

    def test_metadata_round_trip_and_signed_feed_comment(self):
        path = self.root / 'appcast.xml'
        # Sparkle embeds its feed signature in an XML comment after the XML declaration.
        path.write_bytes(path.read_bytes().replace(b'<rss ', b'<!-- sparkle signing metadata -->\n<rss ', 1))
        release.verify_appcast('v0.2.0', self.root)

    def test_rejects_wrong_update_version(self):
        self.mutate(lambda item: setattr(item.find('{%s}version' % release.SPARKLE), 'text', '0.1.0'))
        with self.assertRaisesRegex(ValueError, 'version mismatch'):
            release.verify_appcast('v0.2.0', self.root)

    def test_rejects_download_from_other_origin(self):
        self.mutate(lambda item: item.find('enclosure').set('url', 'https://untrusted.invalid/update.dmg'))
        with self.assertRaisesRegex(ValueError, 'Unexpected update URL'):
            release.verify_appcast('v0.2.0', self.root)

    def test_rejects_mismatched_archive_size(self):
        self.mutate(lambda item: item.find('enclosure').set('length', '42'))
        with self.assertRaisesRegex(ValueError, 'length mismatch'):
            release.verify_appcast('v0.2.0', self.root)

    def test_rejects_missing_or_invalid_signature(self):
        for signature in ('', 'invalid', base64.b64encode(bytes(32)).decode('ascii')):
            with self.subTest(signature=signature):
                with self.assertRaisesRegex(ValueError, 'signature'):
                    release.appcast('v0.2.0', self.root, signature)

    def test_rejects_multiple_update_candidates(self):
        self.mutate(lambda item: ET.SubElement(item, 'enclosure'))
        with self.assertRaisesRegex(ValueError, 'exactly one update archive'):
            release.verify_appcast('v0.2.0', self.root)


if __name__ == '__main__':
    unittest.main()
