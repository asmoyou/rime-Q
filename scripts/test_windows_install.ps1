# Destructive installer lifecycle tests are restricted to a disposable GitHub runner.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'Run installation lifecycle tests only on a disposable GitHub Actions runner.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The disposable runner must provide an administrator token.' }
if (Test-Path 'HKLM:\Software\RimeQ') { throw 'Existing Rime Q installation found; refusing to replace it for a test.' }

. "$PSScriptRoot/windows_lifecycle_process.ps1"

$setup = (Resolve-Path 'dist/RimeQ-0.4.0-windows-x64.exe').Path
Invoke-RimeQ $setup '--install-elevated --silent'
$installed = (Get-ItemProperty 'HKLM:\Software\RimeQ').ActiveDirectory
$programRoot = Join-Path $env:ProgramFiles 'RimeQ'
if (-not $installed.StartsWith($programRoot + '\versions\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected installation path.' }
Invoke-RimeQ (Join-Path $installed 'RimeQ.Control.exe') '--enable'
Invoke-RimeQ (Join-Path $installed 'RimeQ.Control.exe') '--verify'
$isolated = Join-Path $env:RUNNER_TEMP 'RimeQ-installed-engine-test'
Invoke-RimeQ (Join-Path $installed 'RimeQ.Broker.exe') ('--smoke "' + $installed + '" "' + $isolated + '"')

$data = Join-Path $env:APPDATA 'RimeQ'
New-Item -ItemType Directory -Force (Join-Path $data 'rime'),(Join-Path $data 'models') | Out-Null
$learning = Join-Path $data 'rime/retention-fixture.txt'
$model = Join-Path $data 'models/wanxiang-lts-zh-hans.gram'
[IO.File]::WriteAllText($learning, 'personal retention fixture')
[IO.File]::WriteAllText($model, 'optional model retention fixture')
$learningHash = (Get-FileHash $learning -Algorithm SHA256).Hash
$modelHash = (Get-FileHash $model -Algorithm SHA256).Hash

Invoke-RimeQ $setup '--install-elevated --silent'
$repaired = (Get-ItemProperty 'HKLM:\Software\RimeQ').ActiveDirectory
if ($repaired -eq $installed) { throw 'Repair did not create a replacement application.' }
if ((Test-Path (Join-Path $installed 'RimeQ.Broker.exe')) -or (Test-Path (Join-Path $installed 'RimeQ.exe'))) { throw 'Repair left obsolete launchers able to reclaim the user engine lock.' }
Invoke-RimeQ (Join-Path $repaired 'RimeQ.Control.exe') '--verify'
if ((Get-FileHash $learning).Hash -ne $learningHash -or (Get-FileHash $model).Hash -ne $modelHash) { throw 'Repair changed personal data.' }

# Change only the installed fixture's fixed file version to exercise the actual
# installer preflight. Restore the exact bytes even if rejection fails.
$broker = Join-Path $repaired 'RimeQ.Broker.exe'
$originalBytes = [IO.File]::ReadAllBytes($broker)
$modifiedBytes = $originalBytes.Clone()
$offsets = @()
for ($i = 0; $i -lt $modifiedBytes.Length - 52; $i++) {
    if ($modifiedBytes[$i] -eq 0xBD -and $modifiedBytes[$i+1] -eq 0x04 -and $modifiedBytes[$i+2] -eq 0xEF -and $modifiedBytes[$i+3] -eq 0xFE) { $offsets += $i }
}
if ($offsets.Count -ne 1) { throw 'Ambiguous fixture version resource.' }
$versionOffset = $offsets[0] + 12
$versionValue = [BitConverter]::ToUInt32($modifiedBytes,$versionOffset)
[BitConverter]::GetBytes([uint32]($versionValue + 1)).CopyTo($modifiedBytes,$versionOffset)
try {
    [IO.File]::WriteAllBytes($broker,$modifiedBytes)
    Invoke-RimeQ $setup '--install-elevated --silent' 1
    if ((Get-ItemProperty 'HKLM:\Software\RimeQ').ActiveDirectory -ne $repaired) { throw 'Downgrade changed registration.' }
} finally { [IO.File]::WriteAllBytes($broker,$originalBytes) }

$control = Join-Path $env:RUNNER_TEMP 'RimeQ-Control-check.exe'
Copy-Item -LiteralPath (Join-Path $repaired 'RimeQ.Control.exe') -Destination $control
Invoke-RimeQ $control '--deactivate'
Invoke-RimeQ $setup '--uninstall-elevated --silent'
$class = '{C13A9B62-413B-45B8-9EF1-884522319760}'
foreach ($hive in @('LocalMachine', 'CurrentUser')) {
    foreach ($view in @('Registry64', 'Registry32')) {
        $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
        try {
            foreach ($path in @("Software\Microsoft\CTF\TIP\$class", "Software\Classes\CLSID\$class")) {
                $key = $root.OpenSubKey($path)
                Write-Output "Uninstall registration: $hive $view $path present=$($null -ne $key)"
                if ($null -ne $key) { $key.Dispose(); throw "Uninstall registration remains: $hive $view $path" }
            }
        } finally { $root.Dispose() }
    }
}
Invoke-RimeQ $control '--verify-absent'
if (Test-Path 'HKLM:\Software\RimeQ') { throw 'Uninstall registration remains.' }
if ((Get-FileHash $learning).Hash -ne $learningHash -or (Get-FileHash $model).Hash -ne $modelHash) { throw 'Uninstall changed personal data.' }
Write-Output 'PASS actual EXE install, enabled profile, installed engine, repair, downgrade rejection, unregister and personal-data retention. External host typing is a separate acceptance test.'
