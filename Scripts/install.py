#!/usr/bin/env python3
"""Install only this app, preserve preferences, and refresh nested registration."""
import argparse, ctypes, datetime, errno, json, os, plistlib, shutil, signal, subprocess, time, uuid
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('app',type=Path)
p.add_argument('--destination',type=Path,default=Path('/Applications'))
p.add_argument('--no-launch',action='store_true')
a=p.parse_args();source=a.app.resolve();destination=a.destination.expanduser().resolve()/ 'Codex T3.app'
identifier='local.codext3.quota';widgetID=identifier+'.widget'
ls='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'
# Apple's bundled Python may omit os.removexattr; use the Darwin API directly.
remove_attribute=ctypes.CDLL(None,use_errno=True).removexattr
remove_attribute.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int]
remove_attribute.restype=ctypes.c_int
def info(path):return plistlib.loads((path/'Contents/Info.plist').read_bytes())
assert source.name=='Codex T3.app' and info(source)['CFBundleIdentifier']==identifier
assert source!=destination,'Choose a built application outside the installation directory'
if destination.exists():assert info(destination)['CFBundleIdentifier']==identifier
subprocess.run(['codesign','--verify','--deep','--strict',str(source)],check=True)
def owned_processes():
    result=[]
    for row in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
        parts=row.strip().split(None,1)
        if len(parts)==2 and parts[1].startswith(str(destination)+'/Contents/'):result.append(int(parts[0]))
    return result
for pid in owned_processes():
    try:os.kill(pid,signal.SIGTERM)
    except ProcessLookupError:pass
end=time.monotonic()+8
while owned_processes() and time.monotonic()<end:time.sleep(.1)
if owned_processes():raise RuntimeError('Codex T3 has not exited; installation was not changed')
destination.parent.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
backup=root/'build/backups';backup.mkdir(parents=True,exist_ok=True)
if destination.exists():
    archive=backup/('Codex-T3-'+info(destination)['CFBundleShortVersionString']+'-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.zip')
    subprocess.run(['ditto','-c','-k','--keepParent',str(destination),str(archive)],check=True)
    print('Previous version backed up:',archive)
suffix=uuid.uuid4().hex[:8]
stage=destination.with_name('Codex T3-stage-'+suffix+'.app')
previous=destination.with_name('Codex T3-previous-'+suffix+'.bundle-backup')
try:
    shutil.copytree(source,stage)
    # Finder/FileProvider metadata is not part of the signed application.
    for item in [stage,*stage.rglob('*')]:
        for attribute in ['com.apple.FinderInfo','com.apple.ResourceFork']:
            if remove_attribute(os.fsencode(item),attribute.encode(),1) != 0:
                error=ctypes.get_errno()
                if error not in (getattr(errno,'ENOATTR',93),errno.ENOENT):raise OSError(error,os.strerror(error),str(item))
    subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
    if destination.exists():destination.rename(previous)
    stage.rename(destination)
    # Remove registrations only, never delete other copies or user preferences.
    listing=subprocess.check_output(['pluginkit','-m','-A','-D','-v','-i',widgetID],text=True)
    copies={source}
    registered=json.loads(subprocess.check_output(['xcrun','swift',str(root/'Scripts/registered-apps.swift')],text=True))
    for path in registered:
        copy=Path(path)
        if copy==destination or not (copy/'Contents/Info.plist').is_file():continue
        if info(copy).get('CFBundleIdentifier')==identifier:copies.add(copy)
    for row in listing.splitlines():
        tail=row.split('\t')[-1].strip()
        if not tail.startswith('/') or not tail.endswith('/Contents/PlugIns/CodexT3Widget.appex'):continue
        copy=Path(tail).parents[2]
        if copy!=destination and copy.exists() and info(copy).get('CFBundleIdentifier')==identifier:copies.add(copy)
    for copy in copies:
        subprocess.run(['pluginkit','-r',str(copy/'Contents/PlugIns/CodexT3Widget.appex')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
        subprocess.run([ls,'-u',str(copy)],check=False)
    subprocess.run([ls,'-f','-R',str(destination)],check=True)
    subprocess.run(['pluginkit','-a',str(destination/'Contents/PlugIns/CodexT3Widget.appex')],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True)
except Exception:
    if previous.exists():
        if destination.exists():shutil.rmtree(destination)
        previous.rename(destination)
        subprocess.run([ls,'-f','-R',str(destination)],check=False)
        subprocess.run(['pluginkit','-a',str(destination/'Contents/PlugIns/CodexT3Widget.appex')],check=False)
    raise
finally:
    if stage.exists():shutil.rmtree(stage)
if previous.exists():shutil.rmtree(previous)
if not a.no_launch:subprocess.run(['open',str(destination)],check=True)
print('Installed',info(destination)['CFBundleShortVersionString'],'without changing local preferences.')
