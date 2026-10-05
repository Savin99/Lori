#!/usr/bin/env python3
"""Install only the separately identified Lori QA app. No uninstall/reset/copy-to."""
import argparse
import plistlib
import subprocess
import uuid
from pathlib import Path

QA_BUNDLE = 'ru.ilyaqa.lori.local.qa'


def install(app, device, simulator=False):
    uuid.UUID(device)
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != QA_BUNDLE or info.get('CFBundleDisplayName') != 'Lori QA':
        raise ValueError('Refusing to install the personal Lori app for testing')
    if simulator:
        command = ['xcrun', 'simctl', 'install', device, str(app)]
    else:
        command = ['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)]
    subprocess.run(command, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('device')
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    install(args.app, args.device, args.simulator)
