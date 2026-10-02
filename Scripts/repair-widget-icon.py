#!/usr/bin/env python3
"""Manually rebuild a stale, current-user widget-gallery icon index."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import time
import uuid


def service_pids(name):
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,uid=,comm="], text=True)
    result = []
    for row in rows.splitlines():
        fields = row.strip().split(None, 2)
        if len(fields) == 3 and int(fields[1]) == os.getuid() and Path(fields[2]).name == name:
            result.append(int(fields[0]))
    return result


def restart_service(name, force_if_needed=False):
    original = set(service_pids(name))
    for pid in original:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if force_if_needed:
        deadline = time.monotonic() + 2
        while original.intersection(service_pids(name)) and time.monotonic() < deadline:
            time.sleep(0.1)
        for pid in original.intersection(service_pids(name)):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Codex T3.app"))
    parser.add_argument("--dry-run", action="store_true", help="Validate and show the action without changing anything")
    parser.add_argument("--backup-dir", type=Path, default=Path.home() / "Library/Caches/CodexT3/IconRepair")
    args = parser.parse_args()
    if os.getuid() == 0:
        raise RuntimeError("Run as the logged-in desktop user, without sudo")
    app = args.app.expanduser().resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "local.codext3.quota":
        raise RuntimeError("The selected app is not Codex T3")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    cache_root = Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()).resolve()
    cache_directory = cache_root / "com.apple.iconservices"
    index = cache_directory / "store.index"
    if cache_directory.is_symlink() or index.is_symlink():
        raise RuntimeError("Refusing a redirected icon cache")
    if not index.exists():
        raise RuntimeError("No current-user icon index found; this macOS cache layout has not been verified")
    metadata = index.stat()
    if cache_directory.stat().st_uid != os.getuid() or metadata.st_uid != os.getuid() or not stat.S_ISREG(metadata.st_mode):
        raise RuntimeError("The icon index does not belong to the current user")
    print("Application:", app)
    print("Icon index:", index)
    print("This rebuilds the current user's system icon index; other icons may briefly reload.")
    if args.dry_run:
        print("Dry run: no registrations, files, or services changed.")
        return
    backup_directory = args.backup_dir.expanduser().resolve()
    backup_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = backup_directory / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8] + ".index")
    shutil.copy2(index, backup)
    print("Index backup:", backup)
    ls = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
    subprocess.run([ls, "-f", "-R", str(app)], check=True)
    subprocess.run(["/usr/bin/pluginkit", "-a", str(app / "Contents/PlugIns/CodexT3Widget.appex")], check=True)
    index.unlink(missing_ok=True)
    restart_service("iconservicesagent", force_if_needed=True)
    restart_service("NotificationCenter")
    print("Requested icon-index regeneration. Reopen Edit Widgets to verify the app icon.")


if __name__ == "__main__":
    main()
