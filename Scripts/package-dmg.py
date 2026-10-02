#!/usr/bin/env python3
"""Build a flat, bilingual drag-to-Applications installer; never run Finder scripts."""
import argparse, hashlib, plistlib, subprocess, tempfile
from pathlib import Path

try:
    import dmgbuild
except ImportError:
    raise SystemExit('Use Python 3.10+ with Scripts/requirements-packaging.txt in a virtual environment.')
parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
app = args.app.resolve()
root = Path(__file__).resolve().parents[1]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'local.codext3.quota'
assert (app / 'Contents/Resources/LICENSE').read_bytes() == (root / 'LICENSE').read_bytes()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Codex T3')], text=True)
label = 'universal' if 'x86_64' in architectures else 'arm64'
output = (args.output or root / 'dist' / ('Codex-T3-' + info['CFBundleShortVersionString'] + '-' + label + '.dmg')).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='codex-t3-dmg-') as directory:
    background = Path(directory) / 'background.png'
    subprocess.run(['xcrun', 'swift', str(root / 'Scripts/dmg-background.swift'), str(background)], check=True)
    dmgbuild.build_dmg(str(output), 'Codex T3', settings={
        'format': 'UDZO', 'filesystem': 'HFS+', 'files': [str(app)],
        'symlinks': {'Applications': '/Applications'},
        'background': str(background),
        'window_rect': ((180, 160), (660, 512)),
        'default_view': 'icon-view', 'icon_size': 112, 'text_size': 14,
        'icon_locations': {'Codex T3.app': (180, 220), 'Applications': (480, 220)},
        'show_toolbar': False, 'show_status_bar': False, 'show_sidebar': False,
        'show_tab_view': False, 'show_pathbar': False,
        'include_icon_view_settings': True, 'include_list_view_settings': False,
    })
subprocess.run(['hdiutil', 'verify', str(output)], check=True)
checksum = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.dmg.sha256').write_text(checksum + '  ' + output.name + '\n')
print('DMG installer:', output)
