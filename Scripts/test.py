#!/usr/bin/env python3
"""Run isolated regression checks with synthetic accounts; never read real login data."""
import argparse, os, shutil, subprocess, tempfile
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--ui',action='store_true',help='also verify Cocoa window lifecycle on a local desktop')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
source=[root/'Source'/n for n in ['Shared.swift','Transport.swift','Services.swift','WeeklySurplus.swift','QuotaReminders.swift','Updates.swift','SettingsExamples.swift','Host.swift']]
with tempfile.TemporaryDirectory(prefix='codex-t3-tests-') as folder:
    runtime=Path(folder)
    fixture=runtime/'fixtures';fixture.mkdir()
    shutil.copyfile(root/'Tests/Fixtures/fake-codex.py',fixture/'fake-codex.py')
    (fixture/'fake-codex.py').chmod(0o700)
    for name in ['QuotaTests','WeeklySurplusChecks','SettingsChecks','ServicesChecks','ReminderChecks','PerformanceChecks','TransportChecks','UpdateChecks','LocalizationChecks']:
        binary=runtime/name
        subprocess.run(['xcrun','swiftc','-import-objc-header',str(root/'Source/Interop.h'),'-D','QUOTA_TEST_BUILD',*map(str,source),str(root/'Tests'/f'{name}.swift'),'-lz','-lbsm','-o',str(binary)],check=True)
        command=[str(binary)]
        if name=='SettingsChecks':command.append(str(fixture))
        if name=='LocalizationChecks':command.append(str(root))
        if name=='UpdateChecks':
            updates=runtime/'updates'
            subprocess.run(['python3',str(root/'Tests/Fixtures/make-update-fixtures.py'),str(updates),str(binary)],check=True)
            command.append(str(updates))
        if name=='PerformanceChecks' and args.ui:command.append('--ui')
        subprocess.run(command,check=True,timeout=60)
print('All regression checks passed.')
