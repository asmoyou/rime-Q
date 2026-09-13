#!/usr/bin/env python3
"""Prepare only pinned, verified Windows resources. No model downloads."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.cache'
LOCK = json.loads((ROOT / 'dependencies.lock.json').read_text(encoding='utf-8'))


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(name, spec):
    CACHE.mkdir(exist_ok=True)
    target = CACHE / name
    def verified(path):
        return path.is_file() and digest(path) == spec['sha256'] and (
            'bytes' not in spec or path.stat().st_size == spec['bytes'])
    if verified(target):
        return target
    partial = target.with_name(target.name + '.' + uuid.uuid4().hex + '.download')
    for url in [spec['url'], *spec.get('mirrors', [])]:
        try:
            if not url.startswith('https://'):
                raise ValueError('HTTPS required')
            # Windows TLS uses the system certificate store. Values are quoted as PowerShell
            # single-quoted literals and the entire program is UTF-16 encoded, never a shell template.
            quote = lambda value: "'" + str(value).replace("'", "''") + "'"
            script = ("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "
                      "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; "
                      f"Invoke-WebRequest -UseBasicParsing -Uri {quote(url)} -OutFile {quote(partial)} -TimeoutSec 90")
            shell = shutil.which('pwsh') or 'powershell.exe'
            subprocess.run([shell, '-NoProfile', '-NonInteractive', '-EncodedCommand',
                            base64.b64encode(script.encode('utf-16le')).decode()], check=True, capture_output=True)
            if not verified(partial):
                raise ValueError(f'Checksum or size mismatch: {name}')
            partial.replace(target)
            return target
        except (subprocess.CalledProcessError, ValueError):
            partial.unlink(missing_ok=True)
    raise RuntimeError(f'No verified download: {name}')


def extractor():
    tool = CACHE / '7zip/7z.exe'
    installer = fetch('7z-x64.exe', LOCK['windows_build_tools']['seven_zip'])
    bootstrap = fetch('7zr.exe', LOCK['windows_build_tools']['seven_zip_bootstrap'])
    # Re-extract a verified executable so an unrelated cached tool is not trusted.
    subprocess.run([str(bootstrap), 'x', str(installer), '-o' + str(tool.parent), '-y', '-bso0'], check=True)
    return tool


def extract_verified_tar(source, destination):
    destination = Path(destination).resolve()
    with tarfile.open(source) as archive:
        members = archive.getmembers()
        for entry in members:
            if not (destination / entry.name).resolve().is_relative_to(destination) or not (entry.isfile() or entry.isdir()):
                raise ValueError('Unsafe upstream archive entry')
        archive.extractall(destination, members=members, filter='data')
    return destination


def prepare(destination):
    destination = Path(destination).resolve()
    seven = extractor()
    runtime = fetch('rime-windows.7z', LOCK['windows_runtime'])
    opencc = fetch('weasel-runtime.exe', LOCK['windows_opencc_resources'])
    ice = fetch('rime-ice.tar.gz', LOCK['rime_ice'])
    with tempfile.TemporaryDirectory(prefix='rimeq-windows-') as work:
        work = Path(work)
        for archive, folder in [(runtime, 'runtime'), (opencc, 'opencc')]:
            subprocess.run([str(seven), 'x', str(archive), '-o' + str(work / folder), '-aou', '-y', '-bso0'], check=True)
        unpacked = work / 'ice'
        unpacked.mkdir()
        unpacked = extract_verified_tar(ice, unpacked)
        source = unpacked / ('rime-ice-' + LOCK['rime_ice']['revision'])
        data = destination / 'data'
        data.mkdir(parents=True, exist_ok=True)
        (destination / 'runtime').mkdir(parents=True, exist_ok=True)
        shutil.copy2(work / 'runtime/dist/lib/rime.dll', destination / 'runtime/rime.dll')
        shutil.copytree(work / 'opencc/data/opencc', data / 'opencc', dirs_exist_ok=True)
        for folder in ['cn_dicts', 'en_dicts', 'opencc', 'lua']:
            shutil.copytree(source / folder, data / folder, dirs_exist_ok=True)
        for item in source.iterdir():
            if item.suffix in ['.yaml', '.txt'] and item.name not in ['weasel.yaml', 'squirrel.yaml', 'recipe.yaml']:
                shutil.copy2(item, data / item.name)
        for item in (ROOT / 'data').glob('*.yaml'):
            shutil.copy2(item, data / item.name)
        shutil.copytree(ROOT / 'data/lua', data / 'lua', dirs_exist_ok=True)
        licenses = destination / 'licenses'
        licenses.mkdir(exist_ok=True)
        shutil.copy2(ice, licenses / 'rime-ice-source.tar.gz')
        shutil.copy2(source / 'LICENSE', licenses / 'rime-ice-GPL-3.0.txt')
        shutil.copy2(work / 'runtime/version-info.txt', licenses / 'windows-runtime-version-info.txt')
        for folder in ['librime', 'librime-lua', 'librime-octagram']:
            shutil.copy2(ROOT / 'third_party' / folder / 'LICENSE', licenses / (folder + '-LICENSE.txt'))
        for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'dependencies.lock.json']:
            shutil.copy2(ROOT / name, licenses / name)
        for name, metadata in LOCK['windows_licenses'].items():
            original = ROOT / 'third_party/windows/licenses' / (name + '.txt')
            if digest(original) != metadata['sha256']:
                raise ValueError('Third-party license differs from dependency lock: ' + name)
        shutil.copytree(ROOT / 'third_party/windows/licenses', licenses / 'windows', dirs_exist_ok=True)
        model = LOCK['wanxiang_model']
        shutil.copy2(fetch('wanxiang-LICENSE', {'url': model['license_url'], 'sha256': model['license_sha256']}),
                     licenses / 'wanxiang-CC-BY-4.0.txt')
        (destination / 'model.json').write_text(json.dumps(model, ensure_ascii=False, indent=2), encoding='utf-8')
    if list(destination.rglob('*.gram')):
        raise ValueError('Optional models must not be bundled')
    print('Prepared verified Windows engine, base dictionaries and source notices', flush=True)


if __name__ == '__main__':
    import sys
    prepare(sys.argv[1])
