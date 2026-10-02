#!/usr/bin/env python3
"""Fail-closed release utilities. No credentials are read by local validation."""
import hashlib
import base64
import json
import re
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
RELEASES = 'https://github.com/RunaticMoon/worktrail/releases'
ET.register_namespace('sparkle', SPARKLE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(tag, version_file=None):
    require(re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag), 'Expected stable vMAJOR.MINOR.PATCH tag')
    if version_file:
        require(Path(version_file).read_text().strip() == tag[1:], 'Tag/VERSION mismatch')
    return tag[1:]


def assets(tag, directory):
    v = version(tag)
    root = Path(directory)
    paths = sorted(root.glob('*.dmg'))
    require(len(paths) == 1, 'Expected exactly one dmg in %s, found: %s' % (root, ', '.join(p.name for p in paths) or 'none'))
    path = paths[0]
    require(not path.is_symlink() and path.is_file(), 'Asset must be regular file')
    require(re.fullmatch(r'WorkLog-' + re.escape(v) + r'-arm64\.dmg', path.name), 'Unsafe or wrong-version asset name')
    data = path.read_bytes()
    require(len(data) > 0, 'Empty asset')
    return [{'name': path.name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}]


def manifest(tag, directory):
    entries = assets(tag, directory)
    root = Path(directory)
    (root / 'release-manifest.json').write_text(json.dumps({'version': version(tag), 'assets': entries}, indent=2) + '\n')


def verify(tag, directory):
    root = Path(directory)
    entries = assets(tag, directory)
    require(json.loads((root / 'release-manifest.json').read_text()) == {'version': version(tag), 'assets': entries}, 'Manifest/hash mismatch')
    print('Verified exact release assets')


def valid_signature(signature):
    try:
        return len(base64.b64decode(signature, validate=True)) == 64
    except (ValueError, TypeError):
        return False


def appcast(tag, directory, signature):
    """Create deterministic metadata; sign-update.sh signs the resulting XML feed."""
    entry = assets(tag, directory)[0]
    require(valid_signature(signature), 'Invalid Ed25519 archive signature')
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'WorkLog updates'
    ET.SubElement(channel, 'link').text = RELEASES
    ET.SubElement(channel, 'language').text = 'ko'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'WorkLog ' + version(tag)
    ET.SubElement(item, '{%s}version' % SPARKLE).text = version(tag)
    ET.SubElement(item, '{%s}shortVersionString' % SPARKLE).text = version(tag)
    ET.SubElement(item, '{%s}minimumSystemVersion' % SPARKLE).text = '14.0'
    ET.SubElement(item, 'description').text = 'WorkLog 새 버전입니다. 설치 후 앱을 다시 시작합니다.'
    ET.SubElement(item, 'enclosure', {
        'url': RELEASES + '/download/' + tag + '/' + entry['name'],
        'length': str(entry['size']), 'type': 'application/octet-stream',
        '{%s}edSignature' % SPARKLE: signature,
    })
    ET.indent(root)
    (Path(directory) / 'appcast.xml').write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n')


def verify_appcast(tag, directory):
    entry = assets(tag, directory)[0]
    root = ET.fromstring((Path(directory) / 'appcast.xml').read_bytes())
    require(root.tag == 'rss', 'Invalid appcast root')
    items = root.findall('./channel/item')
    require(len(items) == 1, 'Expected exactly one update')
    item = items[0]
    for key in ('version', 'shortVersionString'):
        require(item.findtext('{%s}%s' % (SPARKLE, key)) == version(tag), 'Appcast version mismatch')
    require(item.findtext('{%s}minimumSystemVersion' % SPARKLE) == '14.0', 'Unexpected minimum macOS version')
    enclosures = item.findall('enclosure')
    require(len(enclosures) == 1, 'Expected exactly one update archive')
    enclosure = enclosures[0]
    require(enclosure.get('url') == RELEASES + '/download/' + tag + '/' + entry['name'], 'Unexpected update URL')
    require(enclosure.get('length') == str(entry['size']), 'Appcast archive length mismatch')
    require(valid_signature(enclosure.get('{%s}edSignature' % SPARKLE)), 'Invalid Ed25519 archive signature')
    print('Verified update feed metadata')


def main():
    command, *args = sys.argv[1:]
    if command == 'version':
        print(version(*args))
    elif command == 'manifest':
        manifest(*args)
    elif command == 'verify':
        verify(*args)
    elif command == 'appcast':
        appcast(*args)
    elif command == 'verify-appcast':
        verify_appcast(*args)
    else:
        raise ValueError('Unknown command')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
