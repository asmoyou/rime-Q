#!/usr/bin/env python3
"""Launch native sync/TSF tests in Windows Sandbox; never install on the host."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]


def main():
    run = ROOT / "build-windows" / ("sync-sandbox-" + uuid.uuid4().hex[:10])
    source, output = run / "input", run / "output"
    source.mkdir(parents=True)
    output.mkdir()
    shutil.copytree(ROOT / "build-windows/stage", source / "app")
    # Copy only the interpreter and standard library, never user site packages.
    runtime = Path(sys.base_prefix)
    python = source / "python"
    python.mkdir()
    for file in [runtime/'python.exe', *runtime.glob('*.dll')]:
        shutil.copy2(file, python/file.name)
    shutil.copytree(runtime/'DLLs',python/'DLLs')
    shutil.copytree(runtime/'Lib',python/'Lib',ignore=shutil.ignore_patterns('site-packages','__pycache__','test','tests','idlelib','tkinter','turtledemo'))
    (source/'scripts').mkdir()
    for name in ['test_lan_sync.py','test_lan_sync_native.py']:
        shutil.copy2(ROOT/'scripts'/name,source/'scripts'/name)
    shutil.copy2(ROOT/'sync/target/debug/rimeq-sync.exe',source/'RimeQ.Sync.Test.exe')
    for arch in ["x64", "x86"]:
        (source / arch).mkdir()
        for name in (["rimeq_sync_engine_tests.exe", "rimeq_sync_engine_node.exe"] if arch == "x64" else []) + ["rimeq_tsf_tests.exe", "RimeQ.Tip.dll"]:
            shutil.copy2(ROOT / "build-windows" / arch / "Release" / name, source / arch / name)
    script = r'''
$ErrorActionPreference = 'Stop'
$report = @{ kind='Windows Sandbox'; separate_kernel_vm=$true; passed=@(); failure=$null }
Set-Content C:\RimeQ-TestOutput\started.txt (Get-Date).ToString('o')
try {
    if ($env:USERNAME -ne 'WDAGUtilityAccount' -or (Get-CimInstance Win32_ComputerSystem).Model -notmatch 'Virtual Machine') { throw 'Disposable Windows Sandbox required' }
    $report.os = (Get-CimInstance Win32_OperatingSystem).Version
    $testRoot = Join-Path $env:TEMP 'RimeQ-Sync-Validation'
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    & C:\RimeQ-TestInput\x64\rimeq_sync_engine_tests.exe C:\RimeQ-TestInput\app (Join-Path $testRoot 'engine') *> C:\RimeQ-TestOutput\engine.log
    if ($LASTEXITCODE -ne 0) { throw 'Native sync engine tests failed' }
    $report.passed += 'six real librime stores: composition, stale snapshot, deletion, weight lowering, readback, backup, restart'
    foreach ($arch in @('x64','x86')) {
        $fixture = Join-Path $testRoot $arch
        New-Item -ItemType Directory -Path $fixture | Out-Null
        $server = Start-Process C:\RimeQ-TestInput\x64\rimeq_tsf_tests.exe -ArgumentList @('--serve-fixture','C:\RimeQ-TestInput\app',$fixture) -WindowStyle Hidden -PassThru -RedirectStandardOutput "C:\RimeQ-TestOutput\server-$arch.log" -RedirectStandardError "C:\RimeQ-TestOutput\server-$arch.err"
        $serverHandle = $server.Handle
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while (!(Test-Path (Join-Path $fixture 'fixture.ready'))) {
                if ($server.HasExited -or (Get-Date) -gt $deadline) { throw 'Fixture service did not start' }
                Start-Sleep -Milliseconds 100
            }
            & "C:\RimeQ-TestInput\$arch\rimeq_tsf_tests.exe" "C:\RimeQ-TestInput\$arch\RimeQ.Tip.dll" C:\RimeQ-TestInput\app $fixture --remote *> "C:\RimeQ-TestOutput\client-$arch.log"
            if ($LASTEXITCODE -ne 0) { throw "TSF $arch tests failed" }
            if (!$server.WaitForExit(20000)) { throw 'Fixture shutdown timed out' }
            $server.Refresh()
            if ($server.ExitCode -ne 0) { throw "Fixture exited with code $($server.ExitCode)" }
            $report.passed += "actual $arch TSF context with isolated x64 engine"
        } finally { if (!$server.HasExited) { Stop-Process -Id $server.Id } }
    }
    & C:\RimeQ-TestInput\python\python.exe -B C:\RimeQ-TestInput\scripts\test_lan_sync_native.py --binary C:\RimeQ-TestInput\RimeQ.Sync.Test.exe --native C:\RimeQ-TestInput\x64\rimeq_sync_engine_node.exe --app C:\RimeQ-TestInput\app --output C:\RimeQ-TestOutput\end-to-end.json *> C:\RimeQ-TestOutput\end-to-end.log
    if ($LASTEXITCODE -ne 0) { throw 'Six native engine + TLS end-to-end tests failed' }
    $report.passed += 'six native engines with TLS, durable applied receipts, offline deletion, composition and restart'
} catch { $report.failure = $_.Exception.Message }
$report | ConvertTo-Json -Depth 5 | Set-Content C:\RimeQ-TestOutput\report.json -Encoding UTF8
'''
    (source / "run.ps1").write_text(script, encoding="utf-8-sig")
    (source / "launch.ps1").write_text("Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\\RimeQ-TestInput\\run.ps1') -WindowStyle Hidden\n", encoding="utf-8-sig")
    config = f'''<Configuration>
<VGpu>Disable</VGpu><Networking>Disable</Networking><AudioInput>Disable</AudioInput><VideoInput>Disable</VideoInput><PrinterRedirection>Disable</PrinterRedirection><ClipboardRedirection>Disable</ClipboardRedirection>
<MappedFolders>
<MappedFolder><HostFolder>{escape(str(source))}</HostFolder><SandboxFolder>C:\\RimeQ-TestInput</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
<MappedFolder><HostFolder>{escape(str(output))}</HostFolder><SandboxFolder>C:\\RimeQ-TestOutput</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
</MappedFolders><LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\RimeQ-TestInput\\launch.ps1</Command></LogonCommand>
</Configuration>'''
    path = run / "sync.wsb"
    path.write_text(config, encoding="utf-8")
    env = {k:v for k,v in os.environ.items() if k.upper() in {'SYSTEMROOT','WINDIR','USERPROFILE','APPDATA','LOCALAPPDATA','PATH','TEMP','TMP','PROGRAMDATA'}}
    child = subprocess.Popen([str(Path(os.environ['WINDIR']) / 'System32/WindowsSandbox.exe'), str(path)], env=env)
    print(json.dumps({"sandbox_pid":child.pid,"report":str(output/'report.json'),"configuration":str(path)}))


if __name__ == "__main__":
    main()
