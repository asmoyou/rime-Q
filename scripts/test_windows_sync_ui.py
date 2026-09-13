#!/usr/bin/env python3
"""Show the actual WPF sync window against six loopback-only fixture services."""
from pathlib import Path
import subprocess
import tempfile
import shutil
import build_windows
from test_lan_sync import Node, pair, until

ROOT = Path(__file__).resolve().parents[1]


def main():
    test = ROOT / 'build-windows/Sync.UI.Tests.exe'
    build_windows.csharp(test, sorted((ROOT/'windows/settings').glob('*.cs')) + [ROOT/'windows/tests/sync_ui_tests.cs'],
                         9133, [(ROOT/'windows/settings/Shell.xaml','Shell.xaml')], main='RimeQ.SyncUiTests',console=True)
    shutil.copy2(ROOT/'windows/resources/app.config', test.with_suffix('.exe.config'))
    with tempfile.TemporaryDirectory(prefix='rimeq-sync-ui-') as temporary:
        nodes=[]
        try:
            for i in range(6):
                parent=Path(temporary)/f'node-{i}';parent.mkdir()
                nodes.append(Node(ROOT/'sync/target/debug/rimeq-sync.exe',parent/'sync',f'Test device {i}'))
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/'artifacts/sync-ui-join.png'),'join'],check=True,timeout=30)
            nodes[0].call('create',group='我的电脑 · 沙盒测试',name=nodes[0].name)
            for node in nodes[1:]:pair(nodes[0],node)
            until(lambda:len(nodes[0].call('status')['members'])==6,'six members not present')
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/'artifacts/sync-ui-six.png'),'group'],check=True,timeout=40)
        finally:
            for node in nodes:node.stop()


if __name__=='__main__':main()
