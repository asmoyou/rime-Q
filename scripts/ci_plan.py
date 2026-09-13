#!/usr/bin/env python3
"""Select CI jobs from the complete Git diff; unknown inputs run all jobs."""
import json
import os
from pathlib import Path
import subprocess


JOBS = frozenset({"core", "sync", "mac", "windows"})
MAC_SCRIPTS = {
    "build_macos.py", "install_macos.py", "input_source.swift", "create_icons.swift",
    "prepare_resources.py", "verify_macos_package.py", "test_macos_install_plan.py",
    "test_macos_sync_native.py", "test_optional_model.py", "test_resource_fetch.py",
}
WINDOWS_SCRIPTS = {
    "build_windows.py", "prepare_windows_resources.py", "windows_lifecycle_process.ps1",
}


def affected_jobs(paths):
    selected = set()
    for path in paths:
        if path in {"README.md", "AGENTS.md"} or path.startswith("docs/"):
            continue
        if path.startswith(("macos/", "scripts/macos/")) or path == "Package.swift":
            selected.add("mac")
        elif path.startswith("windows/"):
            selected.add("windows")
        elif path.startswith(("src/", "include/", "tests/", "tools/")) or path == "CMakeLists.txt":
            selected.add("core")
        elif path.startswith("sync/") or path in {"scripts/build_sync.py", "scripts/test_lan_sync.py",
                                                   "scripts/test_lan_sync_native.py",
                                                   "scripts/test_lan_sync_sandboxes.py", ".dockerignore"}:
            selected.update({"sync", "mac", "windows"})
        elif path.startswith("scripts/") and Path(path).name in MAC_SCRIPTS:
            selected.add("mac")
        elif path.startswith("scripts/test_windows_") or (
                path.startswith("scripts/") and Path(path).name in WINDOWS_SCRIPTS):
            selected.add("windows")
        else:
            # Shared dictionaries, licenses, dependencies, CI and new paths must
            # never silently lose coverage when a developer adds a build input.
            selected.update(JOBS)
    return selected


def changed_paths(base, head, *, pull_request=False, cwd=None):
    if pull_request:
        base = subprocess.check_output(
            ["git", "merge-base", base, head], cwd=cwd, text=True, stderr=subprocess.PIPE).strip()
    # Disable rename detection so a move out of a platform still tests its deletion.
    result = subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"],
        cwd=cwd, stderr=subprocess.PIPE)
    return result.decode("utf-8").rstrip("\0").split("\0") if result else []


def plan(event_name, event, *, cwd=None):
    if event_name == "workflow_dispatch":
        return JOBS, "手动全量验收"
    try:
        if event_name == "pull_request":
            pr = event["pull_request"]
            paths = changed_paths(pr["base"]["sha"], pr["head"]["sha"], pull_request=True, cwd=cwd)
        elif event_name == "push":
            paths = changed_paths(event["before"], event["after"], cwd=cwd)
        else:
            return JOBS, "未知事件，全量验收"
    except (KeyError, subprocess.CalledProcessError, UnicodeError):
        return JOBS, "无法完整确定改动范围，全量验收"
    selected = affected_jobs(paths)
    if event_name == "push" and selected:
        return JOBS, "main 代码变更，全量验收"
    return selected, "按完整改动范围选择任务" if selected else "仅文档变更，轻量检查"


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    selected, reason = plan(os.environ["GITHUB_EVENT_NAME"], event)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for job in sorted(JOBS):
            output.write(f"{job}={str(job in selected).lower()}\n")
    summary = reason + "：" + (", ".join(sorted(selected)) or "无构建任务")
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(summary + "\n")


if __name__ == "__main__":
    main()
