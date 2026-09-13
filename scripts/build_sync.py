#!/usr/bin/env python3
"""Build the shared sync helper and preserve locked dependency provenance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build(destination: Path, notices: Path, universal=False):
    project = ROOT / "sync"
    env = os.environ.copy()
    if os.name == "nt":
        env["RUSTFLAGS"] = "-C target-feature=+crt-static"
    elif universal:
        env["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
    targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"] if universal else [None]
    binaries = []
    for target in targets:
        if target:
            subprocess.run(["rustup", "target", "add", target], cwd=project, env=env, check=True)
        arguments = ["cargo", "build", "--release", "--locked"]
        if target:
            arguments.extend(["--target", target])
        subprocess.run(arguments, cwd=project, env=env, check=True)
        binaries.append(project / "target" / (target or "") / "release" / ("rimeq-sync.exe" if os.name == "nt" else "rimeq-sync"))
    destination.parent.mkdir(parents=True, exist_ok=True)
    if universal:
        subprocess.run(["lipo", "-create", *map(str, binaries), "-output", str(destination)], check=True)
    else:
        shutil.copy2(binaries[0], destination)
    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--format-version", "1"], cwd=project, env=env))
    notices.mkdir(parents=True, exist_ok=True)
    locked = { (p["name"], p["version"]): p.get("checksum") for p in __import__("tomllib").loads((project / "Cargo.lock").read_text())["package"] }
    records = []
    for package in sorted(metadata["packages"], key=lambda p:(p["name"],p["version"])):
        if package["source"] is None:
            continue
        directory = Path(package["manifest_path"]).parent
        target = notices / (package["name"] + "-" + package["version"])
        target.mkdir(exist_ok=True)
        files = [p for p in directory.iterdir() if p.is_file() and p.name.lower().startswith(("license", "licence", "copying", "notice", "copyright", "authors"))]
        license_file = package.get("license_file")
        if license_file and (directory / license_file).is_file():
            files.append(directory / license_file)
        supplement = project / "notices" / (package["name"] + "-" + package["version"])
        if supplement.is_dir():
            for record in json.loads((supplement / "source.json").read_text(encoding="utf-8")):
                file = supplement / record["file"]
                if hashlib.sha256(file.read_bytes()).hexdigest() != record["sha256"]:
                    raise RuntimeError("Supplemental license checksum mismatch")
                files.append(file)
            shutil.copy2(supplement / "source.json", target / "source.json")
        shared_notice = None
        if not files and package["name"] in {"winapi-i686-pc-windows-gnu", "winapi-x86_64-pc-windows-gnu"}:
            parent = next(p for p in metadata["packages"] if p["name"] == "winapi" and p["repository"] == package["repository"])
            files.extend(p for p in Path(parent["manifest_path"]).parent.iterdir() if p.is_file() and p.name.startswith("LICENSE"))
            shared_notice = parent["name"] + "-" + parent["version"]
        if not files:
            raise RuntimeError("Missing license text for " + package["name"])
        for file in set(files):
            shutil.copy2(file, target / file.name)
        records.append({"name":package["name"],"version":package["version"],"source":package["source"],"repository":package.get("repository"),
                        "license":package.get("license"),"archive_sha256":locked[(package["name"],package["version"])],
                        "license_files":[p.name for p in sorted(set(files))], "shared_upstream_notice":shared_notice})
    shutil.copy2(project / "Cargo.lock", notices / "Cargo.lock")
    (notices / "dependencies.json").write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
    (notices / "build.json").write_text(json.dumps({"binary_sha256":hashlib.sha256(destination.read_bytes()).hexdigest(),"lock_sha256":hashlib.sha256((project/"Cargo.lock").read_bytes()).hexdigest(),
        "rustc":subprocess.check_output(["rustc","--version"],cwd=project,text=True).strip()},indent=2),encoding="utf-8")


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--output",required=True,type=Path)
    parser.add_argument("--notices",required=True,type=Path)
    parser.add_argument("--universal",action="store_true")
    args=parser.parse_args()
    build(args.output.resolve(),args.notices.resolve(),args.universal)
