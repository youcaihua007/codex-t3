#!/usr/bin/env python3
"""Create signed, synthetic app/ZIP fixtures inside the test's temporary directory."""
import plistlib, shutil, stat, subprocess, sys, warnings, zipfile
from pathlib import Path
root=Path(sys.argv[1]);binary=Path(sys.argv[2]);root.mkdir(parents=True,exist_ok=True)
def application(label,version,repository=None):
    app=root/label/'Codex T3.app';widget=app/'Contents/PlugIns/CodexT3Widget.appex'
    for bundle,name,identifier,kind in [(widget,'CodexT3Widget','local.codext3.quota.widget','XPC!'),(app,'Codex T3','local.codext3.quota','APPL')]:
        (bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
        shutil.copyfile(binary,bundle/'Contents/MacOS'/name);(bundle/'Contents/MacOS'/name).chmod(0o755)
        info={'CFBundleIdentifier':identifier,'CFBundleName':name,'CFBundleExecutable':name,'CFBundlePackageType':kind,'CFBundleShortVersionString':version,'CFBundleVersion':'1','LSMinimumSystemVersion':'14.0'}
        if bundle==app and repository:info['CodexT3RepositoryURL']=repository
        (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign','--force','--sign','-',str(bundle)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return app
application('current','2.9.2','https://github.com/example/Codex-T3');new=application('incoming','3.0.0')
application('unconfigured-current','2.9.2')
application('fixed-current','2.9.2','https://github.com/example/Codex-T3')
subprocess.run(['ditto','-c','-k','--keepParent',str(new),str(root/'good.zip')],check=True)
with zipfile.ZipFile(root/'traversal.zip','w') as z:z.writestr('../outside.txt','never extract')
with zipfile.ZipFile(root/'symlink.zip','w') as z:
    entry=zipfile.ZipInfo('Codex T3.app/Contents/link');entry.create_system=3;entry.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(entry,'/tmp')
with warnings.catch_warnings():
    warnings.simplefilter('ignore')
    with zipfile.ZipFile(root/'duplicate.zip','w') as z:z.writestr('same.txt','a');z.writestr('same.txt','b')
with zipfile.ZipFile(root/'bomb.zip','w') as z:z.writestr('too-large.txt','a')
data=bytearray((root/'bomb.zip').read_bytes());offset=data.index(b'PK\x01\x02');data[offset+24:offset+28]=(300*1024*1024).to_bytes(4,'little');(root/'bomb.zip').write_bytes(data)
data=bytearray((root/'good.zip').read_bytes());data[30]^=1;(root/'mismatch.zip').write_bytes(data)
with zipfile.ZipFile(root/'hidden-bomb.zip','w',compression=zipfile.ZIP_DEFLATED) as z:z.writestr('payload.txt',b'0'*(2*1024*1024))
data=bytearray((root/'hidden-bomb.zip').read_bytes());offset=data.index(b'PK\x01\x02');data[offset+24:offset+28]=(1).to_bytes(4,'little');data[22:26]=(1).to_bytes(4,'little');(root/'hidden-bomb.zip').write_bytes(data)
with zipfile.ZipFile(root/'bad-crc.zip','w') as z:z.writestr('payload.txt','check')
data=bytearray((root/'bad-crc.zip').read_bytes());offset=data.index(b'PK\x01\x02');data[offset+16]^=1;(root/'bad-crc.zip').write_bytes(data)
