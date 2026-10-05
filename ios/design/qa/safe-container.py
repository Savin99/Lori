#!/usr/bin/env python3
"""Append-only fixtures for Lori QA on an explicitly selected simulator."""
import argparse
import json
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path

QA_BUNDLE = 'ru.ilyaqa.lori.local.qa'


def container_for(device):
    uuid.UUID(device)  # No ambiguous "booted" or device names.
    listing = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    if not any(d['udid'] == device for group in listing['devices'].values() for d in group):
        raise ValueError('An explicit available simulator UUID is required')
    path = Path(subprocess.check_output(
        ['xcrun', 'simctl', 'get_app_container', device, QA_BUNDLE, 'data'], text=True).strip())
    expected = Path.home() / 'Library/Developer/CoreSimulator/Devices' / device / 'data/Containers/Data/Application'
    if path.parent.resolve() != expected.resolve() or path.is_symlink():
        raise ValueError('Unexpected simulator container path')
    metadata = plistlib.loads((path / '.com.apple.mobile_container_manager.metadata.plist').read_bytes())
    if metadata.get('MCMMetadataIdentifier') != QA_BUNDLE:
        raise ValueError('Refusing a non-QA container')
    return path


def copy_new(source, container, relative):
    """Never replace or delete existing files, including symlink targets."""
    relative = Path(relative)
    # Documents/Inbox is where iOS leaves files shared to Lori ("Open in"); the
    # app drains it into the attachment panel and removes it.
    allowed = ('Documents/Lori/Workspace', 'Documents/Lori/Models',
               'Library/Application Support/Lori/Models', 'Documents/Lori/RecoveryProbe',
               'Documents/Inbox')
    if relative.is_absolute() or '..' in relative.parts or not any(
            relative == Path(p) or Path(p) in relative.parents for p in allowed):
        raise ValueError('Destination must be a QA fixture directory')
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Source must be a real directory')
    nodes = [source, *source.rglob('*')]
    if any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in nodes):
        raise ValueError('Links and special files are not fixtures')
    destination = container / relative
    pairs = [(p, destination / p.relative_to(source)) for p in nodes]
    for src, dst in pairs:
        for ancestor in [dst, *dst.parents]:
            if ancestor == container:
                break
            if ancestor.is_symlink():
                raise ValueError('Destination contains a symbolic link')
        if dst.exists() and (src.is_file() or not dst.is_dir()):
            raise FileExistsError(f'Refusing to overwrite {dst.name}')
    for src, dst in pairs:
        if src.is_dir():
            dst.mkdir(parents=True, exist_ok=True)
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            with src.open('rb') as incoming, dst.open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('device')
    parser.add_argument('source', type=Path)
    parser.add_argument('destination')
    args = parser.parse_args()
    copy_new(args.source, container_for(args.device), args.destination)
    print('Added fixtures to Lori QA; existing files were preserved.')


if __name__ == '__main__':
    main()
