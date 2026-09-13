#!/usr/bin/env python3
"""Build the standalone Windows client using MSVC and the Windows .NET Framework."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import zipfile
from prepare_windows_resources import prepare, ROOT, LOCK, digest
from dictionary_catalog import write_windows_catalog


def run(*arguments):
    subprocess.run([str(arg) for arg in arguments], check=True, cwd=ROOT)


def resource_fingerprint():
    sources = {str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'data').rglob('*')) if p.is_file()}
    dependencies = {name: LOCK[name] for name in ['windows_runtime', 'windows_opencc_resources', 'rime_ice', 'wanxiang_model']}
    return hashlib.sha256(json.dumps([sources, dependencies], sort_keys=True).encode()).hexdigest()


def record_resources(stage):
    files = [stage / 'runtime/rime.dll', stage / 'model.json', stage / 'dictionaries.json', stage / 'licenses/rime-ice-source.tar.gz',
             *sorted((stage / 'data').rglob('*'))]
    record = {'source_fingerprint': resource_fingerprint(), 'files': {
        str(p.relative_to(stage)).replace('\\','/'): digest(p) for p in files if p.is_file()}}
    (stage / 'resources.lock.json').write_text(json.dumps(record, indent=2), encoding='utf-8')


def verify_resources(stage):
    record = json.loads((stage / 'resources.lock.json').read_text(encoding='utf-8'))
    if record['source_fingerprint'] != resource_fingerprint(): raise RuntimeError('Input sources changed; rebuild without --reuse-resources')
    for name, expected in record['files'].items():
        path = (stage / name).resolve()
        if not path.is_relative_to(stage.resolve()) or not path.is_file() or digest(path) != expected:
            raise RuntimeError('Resource cache differs from its verified build: ' + name)
    if list(stage.rglob('*.gram')): raise RuntimeError('Optional model found in resource cache')


def icon(path):
    shutil.copy2(ROOT / 'windows/resources/RimeQ.ico', path)


def compiler():
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    installation = subprocess.check_output([str(vswhere), '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], text=True).strip()
    path = Path(installation) / 'MSBuild/Current/Bin/Roslyn/csc.exe'
    if not path.is_file(): raise RuntimeError('Install Visual Studio C++ Build Tools and MSBuild')
    return path


def csharp(output, sources, build, resources=(), main=None, console=False):
    framework = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319'
    references = ['mscorlib', 'System', 'System.Core', 'System.Net.Http', 'System.Web.Extensions', 'System.Drawing',
                  'System.Windows.Forms', 'System.Xaml', 'System.Xml', 'Microsoft.CSharp', 'System.IO.Compression', 'System.IO.Compression.FileSystem']
    options = [compiler(), '/nologo', '/utf8output', '/langversion:latest', '/optimize+', '/platform:x64', '/target:' + ('exe' if console else 'winexe'), '/out:' + str(output),
               '/win32manifest:' + str(ROOT / 'windows/resources/app.manifest'), '/win32icon:' + str(ROOT / 'build-windows/RimeQ.ico')]
    for name in references: options.append('/reference:' + str(framework / (name + '.dll')))
    for name in ['PresentationCore', 'PresentationFramework', 'WindowsBase', 'UIAutomationTypes']: options.append('/reference:' + str(framework / 'WPF' / (name + '.dll')))
    for path, name in resources: options.append('/resource:' + str(path) + ',' + name)
    if main: options.append('/main:' + main)
    metadata = ROOT / 'build-windows/AssemblyVersion.cs'
    metadata.write_text('using System.Reflection;\n[assembly: AssemblyTitle("Rime Q")]\n[assembly: AssemblyProduct("Rime Q")]\n'
                        f'[assembly: AssemblyVersion("0.4.0.{build}")]\n[assembly: AssemblyFileVersion("0.4.0.{build}")]\n', encoding='utf-8')
    options.extend([metadata, *sources]); run(*options)


def build(args):
    if os.name != 'nt': raise RuntimeError('The Windows client must be built on Windows')
    if args.build < 1 or args.build > 65535: raise ValueError('Windows build must be 1..65535')
    output = ROOT / 'build-windows'; output.mkdir(exist_ok=True); icon(output / 'RimeQ.ico')
    for arch, platform in [('x64', 'x64'), ('x86', 'Win32')]:
        run('cmake', '-S', 'windows', '-B', output / arch, '-G', 'Visual Studio 17 2022', '-A', platform,
            '-DRIMEQ_BUILD_TSF=ON', '-DRIMEQ_BUILD_NUMBER=' + str(args.build))
        run('cmake', '--build', output / arch, '--config', 'Release', '--parallel')
        run('ctest', '--test-dir', output / arch, '-C', 'Release', '--output-on-failure')
    stage = output / 'stage'
    if not args.reuse_resources:
        prepare(stage)
        write_windows_catalog(stage, LOCK)
        # Deploy into a clean build-only user directory, then ship only compiled input resources.
        import tempfile
        with tempfile.TemporaryDirectory(prefix='rimeq-deploy-') as user:
            run(output / 'x64/Release/RimeQ.Broker.exe', '--deploy', stage, user)
            shutil.copytree(Path(user) / 'rime/build', stage / 'data/build', dirs_exist_ok=True)
        record_resources(stage)
    elif not (stage / 'data/build/rime_q.schema.yaml').is_file() or not (stage / 'licenses/rime-ice-source.tar.gz').is_file():
        raise RuntimeError('Resource cache incomplete; run without --reuse-resources')
    else:
        verify_resources(stage)
    for arch in ['x64', 'x86']:
        (stage / arch).mkdir(exist_ok=True)
        shutil.copy2(output / arch / 'Release/RimeQ.Tip.dll', stage / arch / 'RimeQ.Tip.dll')
    for name in ['RimeQ.Broker.exe', 'RimeQ.Control.exe', 'RimeQ.Visuals.dll']:
        if (output / 'x64/Release' / name).is_file(): shutil.copy2(output / 'x64/Release' / name, stage / name)
    shutil.copy2(output / 'RimeQ.ico', stage / 'RimeQ.ico')
    csharp(stage / 'RimeQ.exe', sorted((ROOT / 'windows/settings').glob('*.cs')), args.build,
           [(ROOT / 'windows/settings/Shell.xaml', 'Shell.xaml')], main='RimeQ.Program')
    csharp(stage / 'RimeQ.Uninstall.exe', [ROOT / 'windows/installer/Setup.cs'], args.build, main='RimeQ.Setup')
    shutil.copy2(ROOT / 'windows/resources/app.config', stage / 'RimeQ.exe.config')
    if (ROOT / 'windows/resources/help').is_dir(): shutil.copytree(ROOT / 'windows/resources/help', stage / 'help', dirs_exist_ok=True)
    for name in ['THIRD_PARTY_NOTICES.md', 'dependencies.lock.json']: shutil.copy2(ROOT / name, stage / 'licenses' / name)
    shutil.copytree(ROOT / 'third_party/windows/licenses', stage / 'licenses/windows', dirs_exist_ok=True)
    if args.smoke:
        import tempfile
        with tempfile.TemporaryDirectory(prefix='rimeq-smoke-') as user:
            run(stage / 'RimeQ.Broker.exe', '--smoke', stage, user)
            run(stage / 'RimeQ.Broker.exe', '--learn-write', stage, user)
            run(stage / 'RimeQ.Broker.exe', '--learn-read', stage, user)
        sources = sorted((ROOT / 'windows/settings').glob('*.cs')) + [ROOT / 'windows/installer/Setup.cs', ROOT / 'windows/tests/SettingsTests.cs']
        csharp(output / 'Settings.Tests.exe', sources, args.build, [(ROOT / 'windows/settings/Shell.xaml', 'Shell.xaml')], main='RimeQ.SettingsTests', console=True)
        shutil.copy2(ROOT / 'windows/resources/app.config', output / 'Settings.Tests.exe.config')
        with tempfile.TemporaryDirectory(prefix='rimeq-settings-') as user:
            run(output / 'Settings.Tests.exe', stage, user, ROOT / 'artifacts/windows-ui')
        run('python', ROOT / 'scripts/test_windows_client.py')
        with tempfile.TemporaryDirectory(prefix='rimeq-candidates-') as user:
            run(output / 'x64/Release/rimeq_candidate_tests.exe', ROOT / 'artifacts/windows-ui', user)
    if args.no_package: return
    if list(stage.rglob('*.gram')): raise RuntimeError('Optional model found in installation payload')
    files = {str(file.relative_to(stage)).replace('\\','/'): hashlib.sha256(file.read_bytes()).hexdigest()
             for file in sorted(stage.rglob('*')) if file.is_file() and file.name != 'payload.json'}
    (stage / 'payload.json').write_text(json.dumps({'version':'0.4.0', 'build':args.build, 'files':files}, indent=2), encoding='utf-8')
    payload = output / 'payload.zip'
    with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(stage.rglob('*')):
            if file.is_file(): archive.write(file, file.relative_to(stage))
    dist = ROOT / 'dist'; dist.mkdir(exist_ok=True)
    setup = dist / 'RimeQ-0.4.0-windows-x64.exe'
    csharp(setup, [ROOT / 'windows/installer/Setup.cs'], args.build, [(payload, 'payload.zip')], main='RimeQ.Setup')
    import tempfile
    with tempfile.TemporaryDirectory(prefix='rimeq-package-') as verified:
        run(setup, '--verify-payload', verified)
    checksum = hashlib.sha256(setup.read_bytes()).hexdigest()
    (dist / 'RimeQ-0.4.0-windows-SHA256SUMS.txt').write_text(checksum + '  ' + setup.name + '\n', encoding='utf-8')
    print(f'Built {setup}\nSHA-256 {checksum}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=int, default=9132)
    parser.add_argument('--reuse-resources', action='store_true')
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--no-package', action='store_true')
    build(parser.parse_args())
