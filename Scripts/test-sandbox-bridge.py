#!/usr/bin/env python3
"""Real sandbox/peer integration, using synthetic bundles and no Codex login."""
import argparse, os, plistlib, select, shutil, subprocess, tempfile, uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--in-applications', action='store_true', help='verify standard installation without a test-only file-read grant')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sources = [root / 'Source' / n for n in ['Shared.swift', 'Transport.swift', 'Services.swift',
           'WeeklySurplus.swift', 'QuotaReminders.swift', 'Updates.swift', 'SettingsExamples.swift', 'Host.swift']]
with tempfile.TemporaryDirectory(prefix='t3-sandbox-', dir='/Applications' if args.in_applications else '/private/tmp') as folder:
    runtime = Path(folder)
    slices = []
    for architecture in ['arm64', 'x86_64']:
        binary = runtime / architecture
        subprocess.run(['xcrun', 'swiftc', '-target', architecture + '-apple-macos14.0',
                        '-import-objc-header', str(root / 'Source/Interop.h'), '-D', 'QUOTA_TEST_BUILD',
                        *map(str, sources), str(root / 'Tests/Fixtures/SandboxBridge.swift'),
                        '-lz','-lbsm', '-o', str(binary)], check=True)
        slices.append(binary)
    universal = runtime / 'fixture'
    subprocess.run(['lipo', '-create', *map(str, slices), '-output', str(universal)], check=True)
    app = runtime / 'Fixture.app'
    widget = app / 'Contents/PlugIns/CodexT3Widget.appex'
    identifier = 'local.codext3.sandbox-test.' + uuid.uuid4().hex
    service = identifier + '.bridge'
    impostor_service = service + '.impostor'
    forbidden = runtime / 'forbidden'; forbidden.mkdir()
    entitlements = runtime / 'fixture.entitlements'
    permissions = {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.temporary-exception.mach-lookup.global-name': [service, impostor_service],
    }
    # /private/tmp is outside standard installation locations. This read-only
    # grant lets the fixture inspect its own enclosing host's signing files.
    if not args.in_applications:
        permissions['com.apple.security.temporary-exception.files.absolute-path.read-only'] = [str(app) + '/']
    entitlements.write_bytes(plistlib.dumps(permissions))
    for bundle, executable, bid in [(widget, 'CodexT3Widget', identifier + '.widget'),
                                     (app, 'Codex T3', identifier)]:
        macos = bundle / 'Contents/MacOS'; macos.mkdir(parents=True)
        shutil.copy2(universal, macos / executable)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bid, 'CFBundleExecutable': executable,
            'CFBundleName': bundle.stem, 'CFBundlePackageType': 'XPC!' if bundle == widget else 'APPL',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'LSUIElement': True
        }))
        command = ['codesign', '--force', '--sign', '-', '--options', 'runtime']
        if bundle == widget: command += ['--entitlements', str(entitlements)]
        subprocess.run(command + [str(bundle)], check=True)
    # Same valid executable with a different signed identity must still be denied.
    outsider = runtime / 'Outsider.app'
    shutil.copytree(widget, outsider)
    outsider_info = outsider / 'Contents/Info.plist'
    info = plistlib.loads(outsider_info.read_bytes()); info['CFBundleIdentifier'] += '.outsider'
    info['CFBundlePackageType'] = 'APPL'
    outsider_info.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements', str(entitlements), str(outsider)], check=True)
    fake_host = runtime / 'FakeHost.app'
    shutil.copytree(app, fake_host)
    fake_info = fake_host / 'Contents/Info.plist'
    info = plistlib.loads(fake_info.read_bytes()); info['CFBundleIdentifier'] += '.impostor'
    fake_info.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(fake_host)], check=True)
    stop = runtime / 'stop'
    host_executable = app / 'Contents/MacOS/Codex T3'
    widget_executable = widget / 'Contents/MacOS/CodexT3Widget'
    home = str(Path.home())
    translated = subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0
    scenarios = [('native host / native widget', [], [])]
    if os.uname().machine == 'arm64' and translated:
        scenarios += [('Rosetta host / native widget', ['arch', '-x86_64'], []),
                      ('native host / Rosetta widget', [], ['arch', '-x86_64'])]
    for label, host_prefix, client_prefix in scenarios:
        stop.unlink(missing_ok=True)
        server = subprocess.Popen([*host_prefix, str(host_executable), 'server', service, str(stop)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([server.stdout], [], [], 10)
            if not ready or server.stdout.readline().strip() != 'READY':
                raise RuntimeError('Fixture bridge failed to start')
            subprocess.run([*client_prefix, str(widget_executable), 'client', service, str(forbidden), home],
                           check=True, timeout=15)
            subprocess.run([str(outsider / 'Contents/MacOS/CodexT3Widget'), 'untrusted', service, str(forbidden), home],
                           check=True, timeout=15)
            print('Passed:', label)
        finally:
            stop.touch()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired: server.terminate(); server.wait(timeout=5)
    stop.unlink(missing_ok=True)
    server = subprocess.Popen([str(fake_host / 'Contents/MacOS/Codex T3'), 'server', impostor_service, str(stop)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([server.stdout], [], [], 10)
        if not ready or server.stdout.readline().strip() != 'READY':
            raise RuntimeError('Impostor fixture failed to start')
        subprocess.run([str(widget_executable), 'impostor', impostor_service, str(forbidden), home], check=True, timeout=15)
    finally:
        stop.touch()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.terminate(); server.wait(timeout=5)
    if not translated: print('Rosetta is unavailable; cross-architecture runtime scenarios skipped.')
print('Real sandbox bridge checks passed; no real accounts or widget state were accessed.')
