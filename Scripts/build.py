#!/usr/bin/env python3
"""Reproducible Release build. Local ad-hoc signing is the default."""
import argparse, hashlib, os, plistlib, re, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--arch',choices=['arm64','universal'],default='arm64')
p.add_argument('--derived-data',type=Path)
p.add_argument('--identity',default='-',help='Developer ID Application identity for a distribution build')
p.add_argument('--repository',help='Public GitHub project URL embedded in About and the updater')
p.add_argument('--team',help='Apple Developer Team ID; do not provide private keys')
a=p.parse_args();root=Path(__file__).resolve().parents[1]
derived=(a.derived_data or Path(tempfile.gettempdir())/('codex-t3-build-'+hashlib.sha256(str(root).encode()).hexdigest()[:10])).resolve()
flags='$(inherited) -file-prefix-map "'+str(root)+'=/Source/CodexT3" -debug-prefix-map "'+str(root)+'=/Source/CodexT3" -file-prefix-map "'+str(Path.home())+'=/BuildUser" -debug-prefix-map "'+str(Path.home())+'=/BuildUser"'
command=['xcodebuild','-project',str(root/'CodexT3.xcodeproj'),'-scheme','Codex T3','-configuration','Release','-derivedDataPath',str(derived),'CODE_SIGN_IDENTITY='+a.identity,'ONLY_ACTIVE_ARCH=NO','ARCHS=arm64 x86_64' if a.arch=='universal' else 'ARCHS=arm64','OTHER_SWIFT_FLAGS='+flags]
if a.repository:
    repository=a.repository.rstrip('/')
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',repository):p.error('--repository must be a public GitHub project URL')
    command+=['CODEX_T3_REPOSITORY_URL='+repository]
if a.team:command+=['DEVELOPMENT_TEAM='+a.team,'CODE_SIGN_STYLE=Manual']
command+=['build']
subprocess.run(command,check=True)
app=derived/'Build/Products/Release/Codex T3.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
for bundle in [app,app/'Contents/PlugIns/CodexT3Widget.appex']:
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    name=info.get('CFBundleIconFile')
    if not name or not info.get('CFBundleIconName'):
        raise RuntimeError('Missing icon declaration in '+bundle.name)
    icon=bundle/'Contents/Resources'/(name if name.endswith('.icns') else name+'.icns')
    if not icon.is_file() or icon.read_bytes()[:4]!=b'icns':
        raise RuntimeError('Missing compiled icon resource in '+bundle.name)
print('\nBuilt application:',app)

# Xcode's ad-hoc base entitlements can otherwise make Release builds debuggable.
for bundle in [app, app/'Contents/PlugIns/CodexT3Widget.appex']:
    result=subprocess.run(['codesign','-d','--entitlements',':-',str(bundle)],capture_output=True,check=True)
    entitlements=plistlib.loads(result.stdout) if result.stdout.strip() else {}
    if entitlements.get('com.apple.security.get-task-allow'):
        raise SystemExit('Release signing unexpectedly allows debugger task access')
