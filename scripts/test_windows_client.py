#!/usr/bin/env python3
"""Run the production x64/x86 TIP against actual TSF contexts and an isolated x64 engine."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run():
    output = ROOT / 'build-windows'
    stage = output / 'stage'
    environment = {key: value for key, value in os.environ.items()
                   if key.upper() in {'SYSTEMROOT','WINDIR','APPDATA','LOCALAPPDATA','TEMP','TMP','USERPROFILE','PATH'}}
    for arch in ['x64', 'x86']:
        with tempfile.TemporaryDirectory(prefix='rimeq-tsf-') as temporary:
            user = Path(temporary)
            # A test copy has no sibling broker/settings executable, preventing a failing
            # connection from launching a live service against the user's real directory.
            client = user / 'client' / arch
            client.mkdir(parents=True)
            tip = client / 'RimeQ.Tip.dll'
            shutil.copy2(output / arch / 'Release/RimeQ.Tip.dll', tip)
            server = subprocess.Popen([str(output / 'x64/Release/rimeq_tsf_tests.exe'), '--serve-fixture', str(stage), str(user)], env=environment)
            try:
                deadline = time.monotonic() + 15
                while not (user / 'fixture.ready').is_file():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Isolated server failed; ensure no live Rime Q broker is running')
                    time.sleep(.05)
                subprocess.run([str(output / arch / 'Release/rimeq_tsf_tests.exe'), str(tip), str(stage), str(user), '--remote'],
                               check=True, timeout=30, env=environment)
                if server.wait(timeout=10) != 0: raise RuntimeError('Fixture server failed')
                print('Passed production ' + arch + ' TIP with isolated x64 librime', flush=True)
            finally:
                if server.poll() is None: server.terminate(); server.wait(timeout=10)


if __name__ == '__main__':
    run()
