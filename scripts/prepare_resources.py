#!/usr/bin/env python3
"""Fetch pinned build dependencies; the shipped input method never downloads resources."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache"
LOCK = json.loads((ROOT / "dependencies.lock.json").read_text())


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def fetch(name, metadata):
    path = CACHE / name
    expected = metadata.get("sha256")
    def verified(candidate):
        return candidate.is_file() and (not expected or digest(candidate) == expected) \
            and ("bytes" not in metadata or candidate.stat().st_size == metadata["bytes"])

    if expected and verified(path):
        return path
    temporary = path.with_suffix(path.suffix + ".download")
    for url in [metadata["url"], *metadata.get("mirrors", [])]:
        try:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https",
                            "--connect-timeout", "20", "--retry", "2", "--output", str(temporary), url], check=True)
            if verified(temporary):
                temporary.replace(path)
                return path
            print(f"Rejected unverified download: {name}; trying the next pinned source", flush=True)
        except subprocess.CalledProcessError:
            print(f"Download unavailable: {name}; trying the next pinned source", flush=True)
        finally:
            temporary.unlink(missing_ok=True)
    raise RuntimeError(f"No verified download for {name}; all sources failed or differed from the pinned checksum/size")


def prepare(destination):
    CACHE.mkdir(exist_ok=True)
    runtime = LOCK["squirrel_runtime"]
    package = fetch("Squirrel-1.1.2.pkg", runtime)
    ice_archive = fetch("rime-ice.tar.gz", LOCK["rime_ice"])
    license_file = fetch("wanxiang-LICENSE", {"url": LOCK["wanxiang_model"]["license_url"],
                                            "sha256": LOCK["wanxiang_model"]["license_sha256"]})
    with tempfile.TemporaryDirectory(prefix="rimeq-resources-") as temporary:
        temporary = Path(temporary)
        expanded = temporary / "package"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        source = expanded / "Payload/Squirrel.app/Contents"
        for relative, expected in runtime["files"].items():
            original = source / "Frameworks" / relative
            if digest(original) != expected:
                raise RuntimeError(f"Unexpected runtime: {relative}")
            target = destination / "Frameworks" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
        ice_root = (temporary / "ice").resolve()
        ice_root.mkdir()
        with tarfile.open(ice_archive) as archive:
            for item in archive.getmembers():
                resolved = (ice_root / item.name).resolve()
                if not resolved.is_relative_to(ice_root) or not (item.isfile() or item.isdir()):
                    raise RuntimeError("Unsupported archive entry")
            archive.extractall(ice_root)
        ice = ice_root / ("rime-ice-" + LOCK["rime_ice"]["revision"])
        shared = destination / "SharedSupport"
        shared.mkdir(parents=True, exist_ok=True)
        # OpenCC compiled dictionaries accompany the official runtime.
        shutil.copytree(source / "SharedSupport/opencc", shared / "opencc", dirs_exist_ok=True)
        for directory in ["cn_dicts", "en_dicts", "lua", "opencc"]:
            shutil.copytree(ice / directory, shared / directory, dirs_exist_ok=True)
        for original in ice.iterdir():
            if original.suffix in [".yaml", ".txt"] and original.name not in ["squirrel.yaml", "weasel.yaml", "recipe.yaml"]:
                shutil.copy2(original, shared / original.name)
        for original in (ROOT / "data").glob("*.yaml"):
            shutil.copy2(original, shared / original.name)
        shutil.copytree(ROOT / "data/lua", shared / "lua", dirs_exist_ok=True)
        notices = destination / "Resources/Licenses"
        notices.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ice / "LICENSE", notices / "rime-ice-GPL-3.0.txt")
        shutil.copy2(license_file, notices / "wanxiang-CC-BY-4.0.txt")
        shutil.copy2(ROOT / "third_party/librime/LICENSE", notices / "librime-BSD-3-Clause.txt")
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", notices / "THIRD_PARTY_NOTICES.md")
        shutil.copy2(ROOT / "dependencies.lock.json", notices / "dependencies.lock.json")
        # Include the exact upstream configuration source, including dictionary maintenance scripts.
        shutil.copy2(ice_archive, notices / "rime-ice-source.tar.gz")
        for original in source.rglob("*"):
            if original.is_file() and any(word in original.name.lower() for word in ["license", "copying", "copyright"]):
                relative = original.relative_to(source)
                target = notices / "runtime" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
    print("Prepared pinned runtime and rime-ice dictionaries; Wanxiang is an optional download", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: prepare_resources.py APP_CONTENTS")
    prepare(Path(sys.argv[1]).resolve())
