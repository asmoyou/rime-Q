"""Isolated WPF lifecycle and memory comparison; never starts the installed broker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import build_windows


def main():
    root = Path(__file__).resolve().parents[1]
    test = root / 'build-windows/Settings.Lifetime.Tests.exe'
    build_windows.csharp(test, sorted((root/'windows/settings').glob('*.cs')) +
                         [root/'windows/tests/settings_lifetime_tests.cs'], 9145,
                         [(root/'windows/settings/Shell.xaml', 'Shell.xaml')],
                         main='RimeQ.SettingsLifetimeTests', console=True)
    shutil.copy2(root/'windows/resources/app.config', test.with_suffix('.exe.config'))
    env = {k:v for k,v in os.environ.items() if k.upper() in
           {'SYSTEMROOT','WINDIR','APPDATA','LOCALAPPDATA','TEMP','TMP','USERPROFILE','PATH'}}
    reports=[]
    with tempfile.TemporaryDirectory(prefix='rimeq-settings-lifetime-') as temporary:
        for mode in ['eager','lazy']:
            report=Path(temporary)/(mode+'.json')
            subprocess.run([str(test),str(root/'build-windows/stage'),str(Path(temporary)/mode),mode,str(report)],
                           env=env,check=True,timeout=60)
            reports.append(json.loads(report.read_text(encoding='utf-8')))
    output=root/'artifacts/settings-lifetime.json';output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps({'scope':'Same WPF controls in separate fresh processes; old eager/hidden lifetime versus lazy/closed lifetime. No broker, sync, real user data or forced GC in product.',
                                  'runs':reports},indent=2)+'\n',encoding='utf-8')
    print(output)


if __name__=='__main__':main()
