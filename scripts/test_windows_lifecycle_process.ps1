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
Write-Output 'PASS lifecycle diagnostics: stdout/stderr, command and exit code, expected rejection, output filtering and concurrent pipe draining.'
