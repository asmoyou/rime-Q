#!/usr/bin/env python3
from pathlib import Path
import hashlib
import subprocess
import tempfile

helper=Path(__file__).parent/'macos/package-scripts/preserve-model.sh'
with tempfile.TemporaryDirectory(prefix='rimeq-model-preservation-') as temporary:
 root=Path(temporary)
 source=root/'source.gram'; source.write_bytes(b'pinned optional model')
 expected=hashlib.sha256(source.read_bytes()).hexdigest()
 destination=root/'models'
 script='''set -eu
. "$1"
as_login_user() { "$@"; }
preserve_rimeq_model "$2" "$3" "$4"
'''
 def preserve(checksum):
  subprocess.run(['/bin/bash','-c',script,'test',str(helper.resolve()),str(source),str(destination),checksum],check=True)
 preserve('0'*64)
 assert not destination.exists()
 preserve(expected)
 target=destination/'wanxiang-lts-zh-hans.gram'
 assert target.read_bytes()==source.read_bytes()
 target.write_bytes(b'existing personal model')
 preserve(expected)
 assert target.read_bytes()==b'existing personal model'
 assert len(list(destination.iterdir()))==1
 print('PASS optional model upgrade preservation: pinned bytes only, no overwrite, no partial files')
