#!/usr/bin/env python3
"""Package the signed build as a separate release asset, not tracked source."""
import argparse, hashlib, json, plistlib, re, subprocess
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
repository=info.get('CodexT3RepositoryURL','').rstrip('/')
version=info['CFBundleShortVersionString']
if not re.fullmatch(r'https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',repository):
    raise SystemExit('A valid embedded GitHub repository is required for the update manifest.')
if not re.fullmatch(r'[0-9]{1,5}\.[0-9]{1,5}(?:\.[0-9]{1,5})?',version):
    raise SystemExit('A numeric release version is required for the update manifest.')
tag='v'+version
assets=[]
for file in [output,output.with_suffix(output.suffix+'.sha256')]:
    assets.append({'name':file.name,'size':file.stat().st_size,
                   'digest':'sha256:'+hashlib.sha256(file.read_bytes()).hexdigest(),
                   'browser_download_url':repository+'/releases/download/'+tag+'/'+file.name})
manifest=output.parent/'update.json'
manifest.write_text(json.dumps({'tag_name':tag,'draft':False,'prerelease':False,'assets':assets},indent=2)+'\n')
print('Release asset:',output)
print('Public update manifest:',manifest)
