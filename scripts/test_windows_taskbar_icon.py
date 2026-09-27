"""Check taskbar artwork without changing system themes or the installed service."""
import os
import subprocess
import build_windows


def main():
    root = build_windows.ROOT
    output = root / 'build-windows/Taskbar.Icon.Tests.exe'
    build_windows.csharp(output, [root / 'windows/settings/TaskbarIcon.cs',
                                 root / 'windows/tests/taskbar_icon_tests.cs'], 9147,
                         main='RimeQ.TaskbarIconTests', console=True)
    env = {k: v for k, v in os.environ.items() if k.upper() in
           {'SYSTEMROOT', 'WINDIR', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'USERPROFILE', 'PATH'}}
    subprocess.run([str(output), str(root / 'artifacts/taskbar-icons')], env=env, check=True, timeout=30)


if __name__ == '__main__':
    main()
