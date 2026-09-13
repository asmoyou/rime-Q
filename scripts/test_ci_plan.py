#!/usr/bin/env python3
"""Regression tests for skipped CI coverage, using real Git histories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from ci_plan import JOBS, affected_jobs, changed_paths, plan


class RoutingTests(unittest.TestCase):
    def test_platform_changes(self):
        for path, expected in {
            "macos/Sources/InputController.swift": {"mac"},
            "scripts/macos/package-scripts/postinstall": {"mac"},
            "Package.swift": {"mac"},
            "scripts/create_icons.swift": {"mac"},
            "windows/tsf/service.cpp": {"windows"},
            "scripts/test_windows_install.ps1": {"windows"},
            "src/core.cpp": {"core"},
            "CMakeLists.txt": {"core"},
            "sync/src/network.rs": {"sync", "mac", "windows"},
            "scripts/build_sync.py": {"sync", "mac", "windows"},
        }.items():
            with self.subTest(path=path):
                self.assertEqual(affected_jobs([path]), expected)

    def test_shared_and_unknown_inputs_keep_full_coverage(self):
        for path in ["data/rime_q.schema.yaml", "dependencies.lock.json", "LICENSE",
                     "THIRD_PARTY_NOTICES.md", ".github/workflows/ci.yml",
                     "scripts/dictionary_catalog.py", "new-platform/client.cpp"]:
            with self.subTest(path=path):
                self.assertEqual(affected_jobs([path]), JOBS)

    def test_only_repository_docs_are_skipped(self):
        self.assertEqual(affected_jobs(["README.md", "AGENTS.md", "docs/VALIDATION.md"]), set())
        self.assertEqual(affected_jobs(["macos/Resources/Help/index.html"]), {"mac"})
        self.assertEqual(affected_jobs(["windows/resources/help/index.html"]), {"windows"})
        self.assertEqual(affected_jobs(["sync/notices/yasna-0.5.2/LICENSE-MIT"]), {"sync", "mac", "windows"})

    def test_manual_and_unknown_events_are_full(self):
        for event in ["workflow_dispatch", "unrecognized"]:
            self.assertEqual(plan(event, {})[0], JOBS)


class GitHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rimeq-ci-plan-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "CI routing fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("README.md")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def write(self, path):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("fixture\n")

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def pr(self, base, head):
        return plan("pull_request", {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}, cwd=self.root)[0]

    def test_pr_uses_merge_base_not_unrelated_base_updates(self):
        self.git("checkout", "-qb", "topic")
        self.write("macos/Sources/Changed.swift")
        head = self.commit()
        self.git("checkout", "-q", "--detach", self.base)
        self.write("windows/unrelated.cpp")
        updated_base = self.commit()
        self.assertEqual(self.pr(updated_base, head), {"mac"})

    def test_rename_to_docs_still_checks_deleted_code(self):
        self.write("macos/Old.swift")
        base = self.commit()
        (self.root / "docs").mkdir()
        self.git("mv", "macos/Old.swift", "docs/Old.swift")
        head = self.commit()
        self.assertEqual(self.pr(base, head), {"mac"})

    def test_more_than_300_files_and_newlines_are_not_truncated(self):
        for i in range(305):
            self.write(f"docs/{i}.md")
        self.write("windows/new\nfile.cpp")
        head = self.commit()
        self.assertEqual(len(changed_paths(self.base, head, cwd=self.root)), 306)
        self.assertEqual(self.pr(self.base, head), {"windows"})

    def test_push_spans_all_commits_and_runs_full_for_code(self):
        self.write("macos/Changed.swift")
        self.commit()
        self.write("docs/last-commit.md")
        head = self.commit()
        self.assertEqual(plan("push", {"before": self.base, "after": head}, cwd=self.root)[0], JOBS)

    def test_documentation_push_is_lightweight(self):
        self.write("docs/change.md")
        head = self.commit()
        self.assertEqual(plan("push", {"before": self.base, "after": head}, cwd=self.root)[0], set())

    def test_missing_diff_falls_back_to_full(self):
        self.assertEqual(plan("push", {"before": "0" * 40, "after": self.base}, cwd=self.root)[0], JOBS)
        self.assertEqual(plan("pull_request", {}, cwd=self.root)[0], JOBS)

    def test_cli_emits_every_job_and_a_summary(self):
        import json
        event = self.root / "event.json"
        output = self.root / "output.txt"
        summary = self.root / "summary.md"
        event.write_text(json.dumps({}))
        env = dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_EVENT_PATH=str(event),
                   GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
        subprocess.run([os.sys.executable, str(Path(__file__).with_name("ci_plan.py"))],
                       env=env, check=True, capture_output=True)
        self.assertEqual(set(output.read_text().splitlines()), {f"{job}=true" for job in JOBS})
        self.assertIn("手动全量验收", summary.read_text())


if __name__ == "__main__":
    unittest.main()
