#!/usr/bin/env python3
"""Install one Rime Q bundle, following RIMES' duplicate-registration and TIS phase model."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "com.asmoyou.inputmethod.RimeQ"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
source = ROOT / "dist/RimeQ.app"
target = Path.home() / "Library/Input Methods/RimeQ.app"


def identity(path):
    try:
        return plistlib.loads((path / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    except (OSError, ValueError):
        return None


def unregister(path):
    subprocess.run([LSREGISTER, "-u", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if os.getuid() == 0:
    raise SystemExit("Use this development installer as the logged-in user")
if identity(source) != IDENTIFIER:
    raise SystemExit("Build first: python3 scripts/build_macos.py")
if (Path("/Library/Input Methods/RimeQ.app")).exists():
    raise SystemExit("A system installation already exists; update it with the PKG instead")
if target.exists() and identity(target) != IDENTIFIER:
    raise SystemExit("An unrelated application occupies the installation path")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
target.parent.mkdir(parents=True, exist_ok=True)

# A raw .app outside its final path can poison LaunchServices/TIS even when merely tested.
unregister(source)
if target.exists():
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    executable = str(target / "Contents/MacOS/RimeQ")
    if any(line.strip().split(maxsplit=1)[-1] == executable for line in processes.splitlines() if line.strip()):
        subprocess.run(["osascript", "-e", 'tell application id "com.asmoyou.inputmethod.RimeQ" to quit'], check=True)
        time.sleep(0.5)
    unregister(target)
    backups = ROOT / ".cache/install-backups"
    backups.mkdir(parents=True, exist_ok=True)
    # Archives have no discoverable app identity and do not contain the personal Rime directory.
    with tarfile.open(backups / ("RimeQ-" + str(time.time_ns()) + ".tar"), "w") as archive:
        archive.add(target, arcname="RimeQ.app")
    shutil.rmtree(target)

for backup in target.parent.glob("RimeQ-previous-*.app.backup"):
    if identity(backup) == IDENTIFIER:
        unregister(backup)
        shutil.rmtree(backup)

# Keep reusable resources as ordinary folders without Contents/Info.plist or an app suffix.
cache = ROOT / ".cache/prepared-resources"
cache.mkdir(parents=True, exist_ok=True)
for directory in ["Frameworks", "SharedSupport"]:
    shutil.copytree(source / "Contents" / directory, cache / directory, dirs_exist_ok=True)
shutil.move(str(source), str(target))
subprocess.run([LSREGISTER, "-f", str(target)], check=True)
subprocess.run(["/usr/bin/open", "-n", "-g", str(target), "--args", "--complete-install"], env={}, check=True)
print("Application installed; activation continues in the user session. A prompt appears only if action is needed.")
