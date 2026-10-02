#!/usr/bin/env python3
"""Package the signed build as a separate release asset, not tracked source."""
import argparse, hashlib, plistlib, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('app',type=Path);p.add_argument('--output',type=Path);a=p.parse_args()
app=a.app.resolve();root=Path(__file__).resolve().parents[1]
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='local.codext3.quota'
assert (app/'Contents/Resources/LICENSE').read_bytes() == (root/'LICENSE').read_bytes()
arch=subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/Codex T3')],text=True).strip()
label='universal' if 'x86_64' in arch else 'arm64'
output=a.output or root/'dist'/('Codex-T3-'+info['CFBundleShortVersionString']+'-'+label+'.zip')
output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['ditto','-c','-k','--keepParent',str(app),str(output)],check=True)
checksum=hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix+'.sha256').write_text(checksum+'  '+output.name+'\n')
print('Release asset:',output)
