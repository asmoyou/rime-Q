# Safe on a development machine: launches only isolated PowerShell fixtures.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_lifecycle_process.ps1"
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$captured = [Collections.Generic.List[string]]::new()
$arguments = '-NoProfile -NonInteractive -Command "[Console]::Out.WriteLine(''enabled-or-completed hr=0x0''); [Console]::Error.WriteLine(''tsf-absence stage=profile-remains hr=0x80004005''); [Console]::Out.WriteLine(''PRIVATE_FIXTURE_MUST_NOT_APPEAR''); exit 7"'
$failed = $false
try {
    Invoke-RimeQ $pwsh $arguments | ForEach-Object { $captured.Add($_) }
} catch {
    if ($_.Exception.Message -notmatch 'pwsh.exe -NoProfile: 7, expected 0') { throw }
    $failed = $true
}
if (-not $failed) { throw 'Unexpected exit status was accepted.' }
if (-not $captured.Contains('enabled-or-completed hr=0x0') -or
    -not $captured.Contains('tsf-absence stage=profile-remains hr=0x80004005')) { throw 'Child diagnostics were lost.' }
if (($captured -join "`n").Contains('PRIVATE_FIXTURE_MUST_NOT_APPEAR')) { throw 'Unfiltered child output was exposed.' }
Invoke-RimeQ $pwsh '-NoProfile -NonInteractive -Command "exit 7"' 7 | Out-Null
$large = '-NoProfile -NonInteractive -Command "$noise = ''x'' * 8192; for ($i=0; $i -lt 64; $i++) { [Console]::Out.WriteLine($noise); [Console]::Error.WriteLine($noise) }; [Console]::Out.WriteLine(''enabled-or-completed hr=0x0'')"'
$result = @(Invoke-RimeQ $pwsh $large)
if ($result -notcontains 'enabled-or-completed hr=0x0') { throw 'Large concurrent output did not complete.' }
$residual = @('tsf-absence stage=profile-remains hr=0x80004005','pending-or-failed hr=0x80004005')
if (-not (Test-RimeQProfileResidual '--verify-absent' 1 $residual)) { throw 'The known TSF enumeration discrepancy was not classified.' }
foreach ($action in @('--enable','--deactivate','--install-elevated','--uninstall-elevated')) {
    if (Test-RimeQProfileResidual $action 1 $residual) { throw "A critical command failure was classified as a profile warning: $action" }
}
foreach ($code in @(0,7)) {
    if (Test-RimeQProfileResidual '--verify-absent' $code $residual) { throw 'An unrelated exit code was classified as a profile warning.' }
}
foreach ($output in @('tsf-absence stage=create-manager hr=0x80004005','tsf-absence stage=enum-profiles hr=0x80004005','tsf-absence stage=profile-remains hr=0x80070005')) {
    if (Test-RimeQProfileResidual '--verify-absent' 1 @($output,'pending-or-failed hr=0x80004005')) { throw 'An API or access error was classified as a profile warning.' }
}
if (Test-RimeQProfileResidual '--verify-absent' 1 @($residual[0])) { throw 'Incomplete diagnostics were accepted as a profile warning.' }
$criticalFailed = $false
try {
    Invoke-RimeQ $pwsh ($arguments -replace 'exit 7','exit 1') -WarnOnProfileRemains | Out-Null
} catch {
    if ($_.Exception.Message -notmatch 'pwsh.exe -NoProfile: 1, expected 0') { throw }
    $criticalFailed = $true
}
if (-not $criticalFailed) { throw 'The warning option suppressed an unrelated process failure.' }
$profileLine = 'tsf-profile type=1 lang=0x804 clsid={C13A9B62-413B-45B8-9EF1-884522319760} profile={984DA75B-478E-49B4-9CB6-945CA5E7AD41} flags=0x1'
$profileOutput = @(Invoke-RimeQ $pwsh ('-NoProfile -NonInteractive -Command "[Console]::Out.WriteLine(''' + $profileLine + ''')"'))
if ($profileOutput -notcontains $profileLine) { throw 'The enumerated profile diagnostics were lost.' }
Write-Output 'PASS lifecycle diagnostics: stdout/stderr, command and exit code, expected rejection, output filtering, concurrent pipe draining and narrowly scoped TSF warning classification.'
