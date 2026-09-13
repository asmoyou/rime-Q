# Uses the real DLLs and the same shared identity in a disposable runner only.
param([string]$BuildRoot = 'build-registration', [switch]$WarnOnTsfProfileRemains)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'Run global registration tests only on a disposable GitHub Actions runner.' }
if (Test-Path 'HKLM:\Software\RimeQ') { throw 'Existing Rime Q installation found.' }
. "$PSScriptRoot/windows_lifecycle_process.ps1"
$identity = '{C13A9B62-413B-45B8-9EF1-884522319760}'
function Assert-NoRegistration {
    foreach ($hive in @('LocalMachine','CurrentUser')) {
        foreach ($view in @('Registry64','Registry32')) {
            $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view)
            try {
                foreach ($path in @("Software\Microsoft\CTF\TIP\$identity","Software\Classes\CLSID\$identity")) {
                    $key = $root.OpenSubKey($path)
                    if ($null -ne $key) { $key.Dispose(); throw "Rime Q registration present: $hive $view $path" }
                }
            } finally { $root.Dispose() }
        }
    }
}
Assert-NoRegistration
$dll64 = (Resolve-Path "$BuildRoot/x64/Release/RimeQ.Tip.dll").Path
$dll32 = (Resolve-Path "$BuildRoot/x86/Release/RimeQ.Tip.dll").Path
$control = (Resolve-Path "$BuildRoot/x64/Release/RimeQ.Control.exe").Path
$reg64 = Join-Path $env:WINDIR 'System32/regsvr32.exe'
$reg32 = Join-Path $env:WINDIR 'SysWOW64/regsvr32.exe'
# Register and repair the same identity across both architectures, then exercise
# the actual user enable/deactivate path before component unregistration.
foreach ($attempt in 1..2) {
    Invoke-RimeQ $reg64 ('/s "' + $dll64 + '"')
    Invoke-RimeQ $reg32 ('/s "' + $dll32 + '"')
}
Invoke-RimeQ $control '--enable'
Invoke-RimeQ $control '--deactivate'
Invoke-RimeQ $reg64 ('/s /u "' + $dll64 + '"')
Invoke-RimeQ $reg32 ('/s /u "' + $dll32 + '"')
# This is the same own-profile cleanup performed by the original user installer.
foreach ($view in @('Registry64','Registry32')) {
    $user = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser',$view)
    try { $user.DeleteSubKeyTree("Software\Microsoft\CTF\TIP\$identity",$false) } finally { $user.Dispose() }
}
Assert-NoRegistration
Write-Output 'PASS actual x64/x86 DLLs with one shared identity: registration, repair, enable, deactivate, unregister and CTF/COM registry cleanup in both views.'
Invoke-RimeQ $control '--verify-absent' -WarnOnProfileRemains:$WarnOnTsfProfileRemains
