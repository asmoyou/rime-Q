#!/usr/bin/env python3
"""Check the emitted PKG, including the relocation rule that caused a misplaced install."""
from pathlib import Path
import subprocess
import sys
import tempfile
import plistlib
import hashlib
import json
from contextlib import contextmanager
import xml.etree.ElementTree as ET


@contextmanager
def unregister_extracted_app(root):
    try:
        yield
    finally:
        for app in root.glob("*/Payload/RimeQ.app"):
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def verify(package):
    files = set(line.removeprefix("./") for line in subprocess.check_output(
        ["pkgutil", "--payload-files", str(package)], text=True).splitlines())
    assert not any(name.endswith(".gram") for name in files), "Optional models must not be bundled"
    assert "RimeQ.app/Contents/Resources/optional-model.json" in files, "Missing optional model download metadata"
    for name in ["rime-ice-source.tar.gz", "rime-ice-GPL-3.0.txt", "wanxiang-CC-BY-4.0.txt",
                 "librime-BSD-3-Clause.txt", "runtime/Resources/LICENSE.txt"]:
        assert "RimeQ.app/Contents/Resources/Licenses/" + name in files, f"Missing dependency source/notice: {name}"
    for name in ["MacOS/RimeQ.Sync", "Resources/Licenses/sync/Cargo.lock", "Resources/Licenses/sync/dependencies.json", "Resources/Licenses/sync/build.json"]:
        assert "RimeQ.app/Contents/" + name in files, f"Missing sync component/provenance: {name}"
    with tempfile.TemporaryDirectory(prefix="rimeq-pkg-check-") as temporary, unregister_extracted_app(Path(temporary) / "package"):
        expanded = Path(temporary) / "package"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        infos = list(expanded.rglob("PackageInfo"))
        assert len(infos) == 1, "Expected exactly one Rime Q payload"
        info = ET.parse(infos[0]).getroot()
        assert info.get("identifier") == "com.asmoyou.inputmethod.RimeQ"
        assert info.get("install-location") == "/Library/Input Methods"
        assert not info.findall("./relocate/bundle"), "Installer can still relocate the app to a stray copy"
        bundles = info.findall("./bundle")
        assert len(bundles) == 1 and bundles[0].get("path", "").removeprefix("./") == "RimeQ.app"
        assert info.find("./scripts/preinstall") is not None, "Missing duplicate-installation guard"
        assert info.find("./scripts/postinstall") is not None, "Missing input-source registration"
        metadata = plistlib.loads((infos[0].parent / "Scripts/package-version.plist").read_bytes())
        assert metadata["Version"] == info.get("version"), "Version guard differs from the packaged release"
        assert metadata["Build"] == bundles[0].get("CFBundleVersion"), "Version guard differs from the packaged build"
        assert (infos[0].parent / "Scripts/version-check.sh").exists(), "Missing preinstall downgrade protection"
        assert not (infos[0].parent / "Scripts/preserve-model.sh").exists(), "Obsolete bundled-model migration helper"
        assert not (infos[0].parent / "Scripts/model-info.plist").exists(), "Obsolete bundled-model migration metadata"
        contents = infos[0].parent / "Payload/RimeQ.app/Contents"
        bundle = plistlib.loads((contents / "Info.plist").read_bytes())
        identifier = "com.asmoyou.inputmethod.RimeQ"
        component = bundle["ComponentInputModeDict"]
        assert component["tsVisibleInputModeOrderedArrayKey"] == [identifier + ".Hans"]
        modes = component["tsInputModeListKey"]
        assert set(modes) == {identifier + ".Hans"}, "English switching must stay inside the single input source"
        for suffix, icon in [(".Hans", "menu.pdf")]:
            mode = modes[identifier + suffix]
            assert mode["TISInputSourceID"] == identifier + suffix
            assert mode["tsInputModeScriptKey"] == "smUnicodeScript"
            assert mode["tsInputModeDefaultStateKey"]
            assert mode["tsInputModeIsVisibleKey"], "The single Rime Q source must be visible"
            assert mode["tsInputModeAlternateMenuTitleKey"] == "Rime Q"
            assert mode["tsInputModeMenuIconFileKey"] == icon
            assert mode["tsInputModeAlternateMenuIconFileKey"] == icon
            assert (contents / "Resources" / icon).read_bytes().startswith(b"%PDF-")
        assert bundle["NSBonjourServices"] == ["_rimeq-sync._tcp"]
        assert "Local typing" in bundle["NSLocalNetworkUsageDescription"]
        for language in ["en", "zh-Hans", "zh-Hant"]:
            strings = (contents / "Resources" / (language + ".lproj") / "InfoPlist.strings").read_text(encoding="utf-16")
            assert '"NSLocalNetworkUsageDescription"' in strings, "Missing localized LAN permission purpose"
            for suffix in [".Hans"]:
                assert f'"{identifier}{suffix}" = "Rime Q";' in strings, "Mode suffix must not duplicate the icon label"
        native_arches = set(subprocess.check_output(["lipo", "-archs", str(contents / "MacOS/RimeQ")], text=True).split())
        sync_arches = set(subprocess.check_output(["lipo", "-archs", str(contents / "MacOS/RimeQ.Sync")], text=True).split())
        assert native_arches == sync_arches, "Sync helper architectures differ from the native client"
        sync_build = json.loads((contents / "Resources/Licenses/sync/build.json").read_text())
        assert sync_build["binary_sha256"] == hashlib.sha256((contents / "MacOS/RimeQ.Sync").read_bytes()).hexdigest(), "Signed sync helper checksum differs from its provenance"
        dependencies = json.loads((contents / "Resources/Licenses/sync/dependencies.json").read_text())
        assert not any(item["name"].startswith("security-framework") for item in dependencies), "Unexpected Keychain dependency"
        imports = subprocess.check_output(["nm", "-u", str(contents / "MacOS/RimeQ.Sync")], text=True)
        assert not any(symbol in imports for symbol in ["_SecKeychain", "_SecItemCopyMatching", "_SecItemAdd", "_SecItemUpdate", "_SecItemDelete"]), "Sync helper imports Keychain APIs"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
        postinstall = infos[0].parent / "Scripts/postinstall"
        script = postinstall.read_text()
        assert '/usr/bin/open -n -g "$APP" --args --complete-install' in script, "Activation must use LaunchServices"
        assert 'as_login_user "$EXE" --register' not in script, "Direct package-script activation can silently fail"
        assert 'as_login_user "$EXE" --verify-runtime' in script, "Installed process readiness must be verified separately from TIS"
        assert 'as_login_user "$EXE" --rimeq-tis-verify-parent' in script and 'as_login_user "$EXE" --rimeq-tis-verify-mode' in script, "Serving process alone is not sufficient to finish activation"
        distribution = ET.parse(expanded / "Distribution").getroot()
        domains = distribution.find("domains")
        assert domains is not None and domains.get("enable_anywhere") == "false"
        assert domains.get("enable_currentUserHome") == "false"
        assert distribution.find("conclusion") is not None, "Missing activation instructions"
        assert distribution.find("welcome") is not None, "Explain permissions before the system asks"
        assert list(expanded.rglob("welcome.html")), "Missing installer introduction resource"
        installation_check = distribution.find("installation-check")
        assert installation_check is not None and installation_check.get("script") == "rimeqCheckInstallation()"
        assert {choice.get("id") for choice in distribution.findall("choice")} == {"install", "upgrade", "repair"}
        assert all(reference.get("onConclusion") not in {"RequireLogout", "RequireRestart", "RequireShutdown"}
                   for reference in distribution.findall("pkg-ref")), "Do not require session changes after successful activation"
    print("PKG verified: fixed system path, relocation disabled, install scripts, activation instructions and dependency sources/notices present")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())
