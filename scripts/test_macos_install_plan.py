#!/usr/bin/env python3
"""Exercise the GUI check and the preinstall guard against the same installed versions."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
identifier = "com.asmoyou.inputmethod.RimeQ"
script = (ROOT / "scripts/macos/installation-check.js").read_text().replace("@PACKAGE_VERSION@", "0.1.5").replace("@PACKAGE_BUILD@", "200")
cases = [(None, None, "install"), ("0.1.4", "300", "upgrade"), ("0.1.5", "199", "repair"),
         ("0.1.5", "200", "repair"), ("0.1.5", "201", "downgrade"), ("0.1.10", "100", "downgrade"),
         ("0.2.0", "100", "downgrade"), ("invalid", "100", "invalid")]
fixtures = [{"exists": version is not None, "info": {"CFBundleIdentifier": identifier,
             "CFBundleShortVersionString": version, "CFBundleVersion": build}, "expected": expected}
            for version, build, expected in cases]
fixtures += [{"exists": True, "info": {"CFBundleIdentifier": "another.application"}, "expected": "conflict"}]
harness = "var fixtures=" + json.dumps(fixtures) + ";\n" + script + "\n" + """
var results = [];
for (var i = 0; i < fixtures.length; i++) {
    var fixture = fixtures[i];
    var system = {files: {fileExistsAtPath: function() { return fixture.exists; }, plistAtPath: function() { return fixture.info; }}};
    var my = {result: {}};
    rimeqCachedPlan = null;
    var allowed = rimeqCheckInstallation();
    results.push({action: rimeqInstallPlan().action, allowed: allowed, message: my.result.message || ""});
}
JSON.stringify(results);
"""
result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-"], input=harness,
                        capture_output=True, text=True, check=True, env={})
results = json.loads(result.stdout)
for fixture, result in zip(fixtures, results):
    assert result["action"] == fixture["expected"], result
    assert result["allowed"] == (fixture["expected"] in {"install", "upgrade", "repair"}), result
    if not result["allowed"]:
        assert result["message"], "Blocked installation needs an explanation"
for version, build, expected in cases:
    result = subprocess.run(["/bin/bash", "-c", '. "$1"; rimeq_install_action "$2" "$3" "$4" "$5"',
        "rimeq-plan-test", str(ROOT / "scripts/macos/package-scripts/version-check.sh"), version or "", build or "", "0.1.5", "200"],
        capture_output=True, text=True, env={})
    if expected == "invalid":
        assert result.returncode != 0
    else:
        assert result.returncode == 0 and result.stdout.strip() == expected, result
print("PASS install plan: fresh install, release upgrade, same-version repair, older-build/version rejection, invalid metadata and identity")
