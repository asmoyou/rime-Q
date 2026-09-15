# Rime Q 0.4.3 Implementation Plan

> For this Codex task: execute locally in the current checkout, with no subagents.

**Goal:** Publish a verified 0.4.3 release for the Windows parity fixes without relabeling the existing 0.4.2 release.

**Architecture:** Both installers carry 0.4.3 in their embedded application versions and filenames. CI builds and installs the actual packages at one target main commit; release attachments come from that run, not an earlier local development package.

**Tech Stack:** Python build scripts, CMake/MSVC and WPF on Windows, Swift/PKG on macOS, GitHub Actions and Releases.

---

### Task 1: Unify Version

**Files:** `scripts/build_macos.py`, `scripts/build_windows.py`, `windows/CMakeLists.txt`, `windows/resources/app.manifest`, `windows/settings/Infrastructure.cs`, `.github/workflows/ci.yml`, `scripts/test_windows_install.ps1`, `README.md`, `docs/WINDOWS.md`.

1. Change current 0.4.2 version literals and package references to 0.4.3. Leave historical validation entries unchanged.
2. Run `rg -n '0\.4\.2' scripts macos windows .github README.md` to verify no current build/install reference remains.
3. Run `python scripts/test_client_parity.py` and `git diff --check`.

### Task 2: Validate Candidate

**Files:** `docs/VALIDATION.md`.

1. Build Windows with `python scripts/build_windows.py --reuse-resources --build 9135` and check the generated filename, embedded version, actual SHA-256 and manifest.
2. Run isolated settings/installer/engine checks affected by the version change. The live Broker occupies the test pipe, so do not stop the user's input method to run the local TSF pipe test.
3. Record passed and untested results; commit and push the version commit to `main`.
4. Wait for every job on that exact SHA, especially Windows package/install and macOS package/install. Fix failures and repeat as needed.

### Task 3: Publish And Check

**Files:** `docs/VALIDATION.md`.

1. Confirm the target SHA is `main`, all related jobs succeeded, and both CI artifacts embed 0.4.3.
2. Create tag `v0.4.3` on that SHA. Create a public GitHub Release using the two CI installers and their SHA-256 files; do not reuse local packages or the v0.4.2 assets.
3. Read back the public Release: tag, asset sizes, downloadable hashes and latest-update response. Record the actual evidence.
4. Check the Windows machine's HKLM active version independently; a still-open installer or declined UAC is not an installed upgrade.
