#!/usr/bin/env python3
"""distribution/release.py 단위 테스트 (Linux에서 실행, macOS 불필요)."""
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

RELEASE_PY = Path(__file__).resolve().parents[1] / 'release.py'
spec = importlib.util.spec_from_file_location('worklog_release', RELEASE_PY)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def write_dmg(directory, name='WorkLog-1.2.3-arm64.dmg', content=b'fake dmg bytes'):
    path = Path(directory) / name
    path.write_bytes(content)
    return path


class VersionTests(unittest.TestCase):
    def test_accepts_stable_tag_matching_version_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            version_file = Path(tmp) / 'VERSION'
            version_file.write_text('1.2.3\n')
            self.assertEqual(release.version('v1.2.3', str(version_file)), '1.2.3')

    def test_accepts_zero_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            version_file = Path(tmp) / 'VERSION'
            version_file.write_text('0.1.0')
            self.assertEqual(release.version('v0.1.0', str(version_file)), '0.1.0')

    def test_rejects_malformed_tags(self):
        for tag in ('v1.2', '1.2.3', 'v01.2.3', 'v1.2.3.4', 'v1.2.3-rc1', 'vx.y.z', ''):
            with self.subTest(tag=tag):
                with self.assertRaises(ValueError):
                    release.version(tag)

    def test_rejects_version_file_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            version_file = Path(tmp) / 'VERSION'
            version_file.write_text('1.2.4\n')
            with self.assertRaises(ValueError):
                release.version('v1.2.3', str(version_file))


class AssetTests(unittest.TestCase):
    def test_rejects_zero_dmg(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)

    def test_rejects_two_dmg(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp)
            (Path(tmp) / 'WorkLog-1.2.3-arm64.copy.dmg').write_bytes(b'x')
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)

    def test_rejects_wrong_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp, name='WorkLog-1.2.4-arm64.dmg')
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)

    def test_rejects_unprefixed_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp, name='App-1.2.3-arm64.dmg')
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)

    def test_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'real.dmg'
            target.write_bytes(b'fake dmg bytes')
            link = Path(tmp) / 'WorkLog-1.2.3-arm64.dmg'
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)

    def test_rejects_empty_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp, content=b'')
            with self.assertRaises(ValueError):
                release.assets('v1.2.3', tmp)


class ManifestVerifyTests(unittest.TestCase):
    def test_manifest_then_verify_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp)
            release.manifest('v1.2.3', tmp)
            text = (Path(tmp) / 'release-manifest.json').read_text()
            self.assertTrue(text.endswith('\n'))
            data = json.loads(text)
            self.assertEqual(data['version'], '1.2.3')
            self.assertEqual(len(data['assets']), 1)
            self.assertEqual(data['assets'][0]['name'], 'WorkLog-1.2.3-arm64.dmg')
            self.assertEqual(data['assets'][0]['size'], len(b'fake dmg bytes'))
            self.assertEqual(data['assets'][0]['sha256'], hashlib.sha256(b'fake dmg bytes').hexdigest())
            # verify는 예외 없이 통과해야 한다.
            release.verify('v1.2.3', tmp)

    def test_verify_detects_one_byte_tamper(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_dmg(tmp)
            release.manifest('v1.2.3', tmp)
            data = bytearray(path.read_bytes())
            data[0] ^= 0x01
            path.write_bytes(bytes(data))
            with self.assertRaises(ValueError):
                release.verify('v1.2.3', tmp)

    def test_verify_requires_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_dmg(tmp)
            with self.assertRaises(OSError):
                release.verify('v1.2.3', tmp)


if __name__ == '__main__':
    unittest.main()
