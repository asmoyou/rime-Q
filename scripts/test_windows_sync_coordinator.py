#!/usr/bin/env python3
"""Run production C# sync coordination against real isolated Rust and librime."""
from pathlib import Path
import os
import subprocess
import tempfile
import build_windows
from test_lan_sync import Node

ROOT = Path(__file__).resolve().parents[1]

def main():
    output = ROOT / 'build-windows/Sync.Coordinator.Tests.exe'
    build_windows.csharp(output, sorted((ROOT/'windows/settings').glob('*.cs')) +
                         [ROOT/'windows/tests/sync_coordinator_tests.cs'], 9138,
                         main='RimeQ.SyncCoordinatorTests', console=True)
    stage = ROOT/'build-windows/stage'
    native = ROOT/'build-windows/x64/Release/rimeq_sync_engine_node.exe'
    env = {k:v for k,v in os.environ.items() if k.upper() in
           {'SYSTEMROOT','WINDIR','APPDATA','LOCALAPPDATA','TEMP','TMP','USERPROFILE','PATH'}}
    with tempfile.TemporaryDirectory(prefix='rimeq-coordinator-') as temporary:
        node = Node(stage/'RimeQ.Sync.exe', Path(temporary)/'sync', 'Synthetic')
        try:
            # .NET pipe writers may emit a UTF-8 preamble under a UTF-8 console.
            # Exercise that exact boundary, independently of the developer locale.
            framing=subprocess.run([str(native),str(stage),temporary],input=b'\xef\xbb\xbfexport\r\nprobe\r\nquit\r\n',
                                   capture_output=True,timeout=30,env=env)
            if framing.returncode or framing.stdout.count(b'RIMEQ-SYNC-TEST ok')!=2:
                raise RuntimeError('Native fixture must accept the UTF-8 BOM and CRLF used by pipe writers')
            node.call('create', group='Synthetic', name='Synthetic')
            subprocess.run([str(output),str(stage),temporary,str(native)],check=True,timeout=90,env=env)
        finally:
            node.stop()

if __name__=='__main__':
    main()
