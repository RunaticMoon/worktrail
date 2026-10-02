#!/usr/bin/env python3
"""Fail-closed release utilities. No credentials are read by local validation."""
import hashlib
import json
import re
import sys
from pathlib import Path


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


def main():
    command, *args = sys.argv[1:]
    if command == 'version':
        print(version(*args))
    elif command == 'manifest':
        manifest(*args)
    elif command == 'verify':
        verify(*args)
    else:
        raise ValueError('Unknown command')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))
