#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "com.asmoyou.inputmethod.RimeQ"


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def icon(path):
    stream = b"BT /F1 15 Tf 2 2 Td (Q) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 18 20] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
               b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"]
    result = b"%PDF-1.4\n"
    offsets = [0]
    for number, value in enumerate(objects, 1):
        offsets.append(len(result))
        result += f"{number} 0 obj\n".encode() + value + b"\nendobj\n"
    start = len(result)
    result += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    result += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    result += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(result)


def build(universal=False, resources=True):
    flags = ["--arch", "arm64", "--arch", "x86_64"] if universal else []
    run("swift", "build", "-c", "release", *flags)
    binary_directory = subprocess.check_output(["swift", "build", "-c", "release", *flags, "--show-bin-path"],
                                                cwd=ROOT, text=True).strip()
    app = ROOT / "dist/RimeQ.app"
    contents = app / "Contents"
    for directory in ["MacOS", "Resources"]:
        (contents / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(Path(binary_directory) / "RimeQ", contents / "MacOS/RimeQ")
    mode = IDENTIFIER + ".Hans"
    metadata = {
        "CFBundleName": "Rime Q", "CFBundleDisplayName": "Rime Q", "CFBundleExecutable": "RimeQ",
        "CFBundleIdentifier": IDENTIFIER, "CFBundleVersion": str(int(time.time())), "CFBundleShortVersionString": "0.1.0",
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "zh-Hans",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleSignature": "????",
        "CFBundleSupportedPlatforms": ["MacOSX"], "LSBackgroundOnly": False,
        "LSMinimumSystemVersion": "13.0", "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        "InputMethodConnectionName": "RimeQ_Connection", "InputMethodServerControllerClass": "RimeQController",
        "InputMethodServerDelegateClass": "RimeQController", "TISInputSourceID": IDENTIFIER,
        "TICapsLockLanguageSwitchCapable": True, "tsInputMethodIconFileKey": "menu.pdf",
        "ComponentInputModeDict": {"tsVisibleInputModeOrderedArrayKey": [mode], "tsInputModeListKey": {
            mode: {"TISInputSourceID": mode, "TISIntendedLanguage": "zh-Hans",
                   "tsInputModeAlternateMenuTitleKey": "Rime Q", "tsInputModeDefaultStateKey": True,
                   "tsInputModeIsVisibleKey": True, "tsInputModePrimaryInScriptKey": True,
                   "tsInputModeKeyEquivalentModifiersKey": 4608,
                   "tsInputModeScriptKey": "smUnicodeScript", "tsInputModeCharacterRepertoireKey": ["Hans", "Hant"],
                   "tsInputModeMenuIconFileKey": "menu.pdf", "tsInputModeAlternateMenuIconFileKey": "menu.pdf",
                   "tsInputModePaletteIconFileKey": "menu.pdf"}}}
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    for language in ["en", "zh-Hans", "zh-Hant"]:
        localized = contents / "Resources" / (language + ".lproj")
        localized.mkdir(exist_ok=True)
        (localized / "InfoPlist.strings").write_bytes(plistlib.dumps({
            "CFBundleName": "Rime Q", "CFBundleDisplayName": "Rime Q",
            IDENTIFIER: "Rime Q", mode: "Rime Q"
        }))
    icon(contents / "Resources/menu.pdf")
    if not resources and not (contents / "SharedSupport/build").is_dir():
        cached = ROOT / ".cache/prepared-resources"
        for directory in ["Frameworks", "SharedSupport"]:
            if (cached / directory).is_dir():
                shutil.copytree(cached / directory, contents / directory, dirs_exist_ok=True)
    if resources:
        run(sys.executable, ROOT / "scripts/prepare_resources.py", contents)
        compiled = contents / "SharedSupport/build"
        if compiled.exists():
            shutil.rmtree(compiled)
        run(contents / "MacOS/RimeQ", "--prepare", compiled)
    elif not (contents / "SharedSupport/build").is_dir():
        raise RuntimeError("No prepared resources; omit --reuse-resources on the first build")
    notices = contents / "Resources/Licenses"
    notices.mkdir(parents=True, exist_ok=True)
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "dependencies.lock.json"]:
        shutil.copy2(ROOT / name, notices / name)
    for name in ["librime-lua", "librime-octagram", "rimes"]:
        shutil.copy2(ROOT / "third_party" / name / "LICENSE", notices / (name + "-LICENSE"))
    for library in (contents / "Frameworks").rglob("*.dylib"):
        run("codesign", "--force", "--sign", "-", library)
    run("codesign", "--force", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    # Developer preview package. Signing/notarization is a later release task.
    package = ROOT / "dist/RimeQ-0.1.0-preview.pkg"
    run("pkgbuild", "--component", app, "--identifier", IDENTIFIER,
        "--version", "0.1.0", "--install-location", "/Library/Input Methods", package)
    print(f"Built {package}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--universal", action="store_true", help="Build both Apple Silicon and Intel")
    parser.add_argument("--reuse-resources", action="store_true", help="Rebuild code using previously prepared data")
    options = parser.parse_args()
    build(options.universal, not options.reuse_resources)
