#!/usr/bin/env python3
"""Check the emitted PKG, including the relocation rule that caused a misplaced install."""
from pathlib import Path
import subprocess
import sys
import tempfile
import plistlib
import xml.etree.ElementTree as ET


def verify(package):
    with tempfile.TemporaryDirectory(prefix="rimeq-pkg-check-") as temporary:
        expanded = Path(temporary) / "package"
        subprocess.run(["pkgutil", "--expand", str(package), str(expanded)], check=True)
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
        postinstall = infos[0].parent / "Scripts/postinstall"
        script = postinstall.read_text()
        assert '/usr/bin/open -n -g "$APP" --args --complete-install' in script, "Activation must use LaunchServices"
        assert 'as_login_user "$EXE" --register' not in script, "Direct package-script activation can silently fail"
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
    print("PKG verified: fixed system path, relocation disabled, install scripts and activation instructions present")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())
