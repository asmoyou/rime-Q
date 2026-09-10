#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import json
from contextlib import contextmanager
import uuid
from dictionary_catalog import write_catalog
from prepare_resources import digest

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "com.asmoyou.inputmethod.RimeQ"
VERSION = "0.3.0"


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


def build_app(app, universal=False, resources=True):
    flags = ["--arch", "arm64", "--arch", "x86_64"] if universal else []
    run("swift", "build", "-c", "release", *flags)
    binary_directory = subprocess.check_output(["swift", "build", "-c", "release", *flags, "--show-bin-path"],
                                                cwd=ROOT, text=True).strip()
    contents = app / "Contents"
    for directory in ["MacOS", "Resources"]:
        (contents / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(Path(binary_directory) / "RimeQ", contents / "MacOS/RimeQ")
    mode = IDENTIFIER + ".Hans"
    metadata = {
        "CFBundleName": "Rime Q", "CFBundleDisplayName": "Rime Q", "CFBundleExecutable": "RimeQ",
        "CFBundleIdentifier": IDENTIFIER, "CFBundleVersion": str(int(time.time())), "CFBundleShortVersionString": VERSION,
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en",
        "CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleSignature": "????",
        "CFBundleSupportedPlatforms": ["MacOSX"], "LSBackgroundOnly": False,
        "NSAppleEventsUsageDescription": "Rime Q asks its previous version to quit during an update. When you choose Log Out, it asks macOS to show the logout confirmation.",
        "LSMinimumSystemVersion": "13.0", "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        "InputMethodConnectionName": IDENTIFIER + "_Connection", "InputMethodServerControllerClass": "RimeQController",
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
    shutil.copytree(ROOT / "macos/Resources", contents / "Resources", dirs_exist_ok=True)
    for language in ["en", "zh-Hans", "zh-Hant"]:
        localized = contents / "Resources" / (language + ".lproj")
        localized.mkdir(exist_ok=True)
        strings = {key: "Rime Q" for key in ["CFBundleName", "CFBundleDisplayName", IDENTIFIER, mode]}
        strings["NSAppleEventsUsageDescription"] = metadata["NSAppleEventsUsageDescription"] if language == "en" else (
            "更新时用于退出仍在运行的旧版 Rime Q；仅当你选择注销账户时，才请求 macOS 显示注销确认。")
        (localized / "InfoPlist.strings").write_text(
            '\n'.join(f'"{key}" = "{value}";' for key, value in strings.items()) + '\n', encoding="utf-16")
    run("swift", ROOT / "scripts/create_icons.swift", contents / "Resources")
    run("iconutil", "-c", "icns", contents / "Resources/AppIcon.iconset", "-o", contents / "Resources/AppIcon.icns")
    shutil.rmtree(contents / "Resources/AppIcon.iconset")
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
        # Cache resources without an application identity for incremental builds.
        for directory in ["Frameworks", "SharedSupport"]:
            shutil.copytree(contents / directory, ROOT / ".cache/prepared-resources" / directory, dirs_exist_ok=True)
        shutil.copytree(contents / "Resources/Licenses", ROOT / ".cache/prepared-resources/Licenses", dirs_exist_ok=True)
    elif not (contents / "SharedSupport/build").is_dir():
        raise RuntimeError("No prepared resources; omit --reuse-resources on the first build")
    else:
        # Resource reuse skips downloads, not local input configuration edits.
        schema_changed = False
        for original in (ROOT / "data").glob("*.yaml"):
            target = contents / "SharedSupport" / original.name
            if not target.exists() or target.read_bytes() != original.read_bytes():
                shutil.copy2(original, target)
                schema_changed = True
        shutil.copytree(ROOT / "data/lua", contents / "SharedSupport/lua", dirs_exist_ok=True)
        if schema_changed:
            compiled = contents / "SharedSupport/build"
            shutil.rmtree(compiled)
            run(contents / "MacOS/RimeQ", "--prepare", compiled)
    lock = json.loads((ROOT / "dependencies.lock.json").read_text())
    model = lock["wanxiang_model"]
    model_file = contents / "SharedSupport" / model["filename"]
    if digest(model_file) != model["sha256"] or model_file.stat().st_size != model["bytes"]:
        raise RuntimeError("Prepared model differs from dependencies.lock.json; rebuild without --reuse-resources")
    write_catalog(contents, lock)
    notices = contents / "Resources/Licenses"
    notices.mkdir(parents=True, exist_ok=True)
    if not resources:
        cached_notices = ROOT / ".cache/prepared-resources/Licenses"
        if not (cached_notices / "rime-ice-source.tar.gz").is_file():
            raise RuntimeError("Cached dependency notices are missing; rebuild without --reuse-resources")
        shutil.copytree(cached_notices, notices, dirs_exist_ok=True)
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "dependencies.lock.json"]:
        shutil.copy2(ROOT / name, notices / name)
    for name in ["librime-lua", "librime-octagram", "rimes"]:
        shutil.copy2(ROOT / "third_party" / name / "LICENSE", notices / (name + "-LICENSE"))
    for library in (contents / "Frameworks").rglob("*.dylib"):
        run("codesign", "--force", "--sign", "-", library)
    run("codesign", "--force", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)


@contextmanager
def unregister_on_exit(app):
    try:
        yield
    finally:
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


@contextmanager
def isolated_smoke_app(app):
    # AppKit windows register their bundle with LaunchServices even when TIS
    # registration is never called. Never run GUI previews with the installed ID.
    with tempfile.TemporaryDirectory(prefix="rimeq-preview-") as temporary:
        preview = Path(temporary) / "RimeQPreview.app"
        contents = preview / "Contents"
        shutil.copytree(app / "Contents/MacOS", contents / "MacOS")
        for name in ["Frameworks", "SharedSupport", "Resources"]:
            (contents / name).symlink_to(app / "Contents" / name, target_is_directory=True)
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        preview_id = IDENTIFIER + ".Preview." + uuid.uuid4().hex
        metadata["CFBundleIdentifier"] = preview_id
        metadata["InputMethodConnectionName"] = preview_id + "_Connection"
        metadata.pop("ComponentInputModeDict", None)
        metadata.pop("TISInputSourceID", None)
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
        run("codesign", "--force", "--sign", "-", preview)
        try:
            yield preview
        finally:
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-u", str(preview)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build(universal=False, resources=True, keep_app=False, smoke=False):
    cache = ROOT / ".cache"
    cache.mkdir(exist_ok=True)
    (ROOT / "dist").mkdir(exist_ok=True)
    retained = ROOT / "dist/RimeQ.app"
    if retained.exists():
        raise RuntimeError("Move the previous dist/RimeQ.app with install_macos.py before building again")
    # Never leave a second discoverable app behind after producing an installer.
    with tempfile.TemporaryDirectory(prefix="rimeq-macos-package-") as temporary, \
            unregister_on_exit(Path(temporary) / "payload/RimeQ.app"):
        staging = Path(temporary)
        payload = staging / "payload"
        app = payload / "RimeQ.app"
        build_app(app, universal, resources)
        if smoke:
            run(sys.executable, ROOT / "scripts/test_macos_install_plan.py")
            run(sys.executable, ROOT / "scripts/test_resource_fetch.py")
            run(app / "Contents/MacOS/RimeQ", "--rimeq-tis-validate-bundle")
            with isolated_smoke_app(app) as preview:
                exe = preview / "Contents/MacOS/RimeQ"
                for command in ["--smoke", "--lua-smoke", "--installation-smoke", "--runtime-smoke", "--maintenance-smoke", "--update-smoke", "--candidate-smoke",
                                "--controller-smoke", "--personal-dictionary-smoke", "--settings-ui-smoke", "--dictionary-resources-smoke"]:
                    run(exe, command)
                run(exe, "--settings-render", ROOT / f"artifacts/settings-{VERSION}")
                run(exe, "--candidate-render", ROOT / f"artifacts/candidates-{VERSION}")
        component = staging / "RimeQ-component.pkg"
        package_scripts = staging / "Scripts"
        shutil.copytree(ROOT / "scripts/macos/package-scripts", package_scripts)
        build_number = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        (package_scripts / "package-version.plist").write_bytes(plistlib.dumps({"Version": VERSION, "Build": build_number}))
        resources = staging / "Resources"
        shutil.copytree(ROOT / "scripts/macos/package-resources", resources)
        for resource in resources.glob("*.html"):
            resource.write_text(resource.read_text().replace("@PACKAGE_VERSION@", VERSION))
        run("pkgbuild", "--root", payload,
            "--component-plist", ROOT / "scripts/macos/component.plist",
            "--scripts", package_scripts,
            "--identifier", IDENTIFIER, "--version", VERSION,
            "--install-location", "/Library/Input Methods", component)
        distribution = staging / "Distribution.xml"
        checks = (ROOT / "scripts/macos/installation-check.js").read_text().replace("@PACKAGE_VERSION@", VERSION).replace("@PACKAGE_BUILD@", build_number)
        choices = []
        for action, title, description in [
            ("install", "安装", "首次安装。内置引擎和词库将安装到系统输入法目录。"),
            ("upgrade", "升级至", "检测到较旧版本。更新应用，保留个人词库、学习记录和设置。"),
            ("repair", "重新安装", "检测到相同版本。重新安装以修复应用，保留个人词库和设置。")
        ]:
            choices.append(f'<choice id="{action}" title="{title} Rime Q {VERSION}" description="{description}" enabled="false" selected="rimeqActionIs(\'{action}\')" visible="rimeqActionIs(\'{action}\')"><pkg-ref id="{IDENTIFIER}"/></choice>')
        distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Rime Q {VERSION}</title>
  <options customize="always" require-scripts="true" hostArchitectures="x86_64,arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <installation-check script="rimeqCheckInstallation()"/>
  <choices-outline><line choice="install"/><line choice="upgrade"/><line choice="repair"/></choices-outline>
  {''.join(choices)}
  <pkg-ref id="{IDENTIFIER}" version="{VERSION}" onConclusion="None">RimeQ-component.pkg</pkg-ref>
  <script><![CDATA[{checks}]]></script>
</installer-gui-script>
''')
        architecture = "universal" if universal else platform.machine()
        package = ROOT / f"dist/RimeQ-{VERSION}-macos-{architecture}.pkg"
        run("productbuild", "--distribution", distribution, "--package-path", staging,
            "--resources", resources, package)
        run(sys.executable, ROOT / "scripts/verify_macos_package.py", package)
        if keep_app:
            shutil.move(str(app), str(retained))
            print(f"Development bundle retained at {retained}; move it with install_macos.py before using the PKG")
    print(f"Built {package}; temporary app bundle removed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--universal", action="store_true", help="Build both Apple Silicon and Intel")
    parser.add_argument("--reuse-resources", action="store_true", help="Rebuild code using previously prepared data")
    parser.add_argument("--keep-app", action="store_true", help="Keep dist/RimeQ.app for the development installer only")
    parser.add_argument("--smoke", action="store_true", help="Verify the bundled engine before packaging")
    options = parser.parse_args()
    build(options.universal, not options.reuse_resources, options.keep_app, options.smoke)
