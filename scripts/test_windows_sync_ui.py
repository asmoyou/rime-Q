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
                nodes.append(Node(ROOT/'build-windows/stage/RimeQ.Sync.exe',parent/'sync',f'Test device {i}'))
            unused=Path(temporary)/'unused';(unused/'sync').mkdir(parents=True)
            (unused/'sync'/'isolated-test-only').touch()
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(unused),str(ROOT/'artifacts/sync-ui-off.png'),'off'],check=True,timeout=30)
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(unused),str(ROOT/'artifacts/sync-ui-off-dark.png'),'off-dark'],check=True,timeout=30)
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(unused),str(ROOT/'artifacts/sync-ui-upgrade.png'),'upgrade'],check=True,timeout=30)
            subprocess.run([str(test),str(unused),str(unused),str(ROOT/'artifacts/sync-ui-error.png'),'error'],check=True,timeout=30)
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/'artifacts/sync-ui-join.png'),'join'],check=True,timeout=30)
            nodes[0].call('create',group='我的电脑 · 沙盒测试',name=nodes[0].name)
            for node in nodes[1:]:pair(nodes[0],node)
            until(lambda:all(len(node.call('status')['members'])==6 for node in nodes),'six members not present on every node',60)
            for node in nodes:node.call('capture',rows=[])
            until(lambda:nodes[0].call('status')['progress']['confirmed']==6 and nodes[0].call('status')['last_sync_at']>0,'confirmation telemetry not present',60)
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/'artifacts/sync-ui-six.png'),'group'],check=True,timeout=40)
            for variant in ('group-dark','group-compact'):
                subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/f'artifacts/sync-ui-{variant}.png'),variant],check=True,timeout=40)
            subprocess.run([str(test),str(ROOT/'build-windows/stage'),str(nodes[0].root.parent),str(ROOT/'artifacts/sync-ui-invite.png'),'invite'],check=True,timeout=40)
        finally:
            for node in nodes:node.stop()


if __name__=='__main__':main()
