# Shared with the non-destructive process-runner regression test.
function Test-RimeQProfileResidual([string]$Action, [int]$ExitCode, [string[]]$Output) {
    return $Action -eq '--verify-absent' -and $ExitCode -eq 1 -and
        $Output -contains 'tsf-absence stage=profile-remains hr=0x80004005' -and
        $Output -contains 'pending-or-failed hr=0x80004005'
}
function Invoke-RimeQ([string]$File, [string]$Arguments, [int]$Expected = 0, [switch]$WarnOnProfileRemains) {
    $action = ($Arguments -split ' ', 2)[0]
    $label = [IO.Path]::GetFileName($File) + ' ' + $action
    Write-Output "Lifecycle command: $label"
    $info = [Diagnostics.ProcessStartInfo]::new($File, $Arguments)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment.Clear()
    foreach ($name in @('APPDATA','LOCALAPPDATA','SystemRoot','WINDIR','TEMP','TMP','USERPROFILE')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $info.Environment[$name] = $value }
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        # Drain both pipes concurrently so a verbose child cannot block on a full pipe.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { throw "Rime Q lifecycle command timed out: $label" }
        $outputLines = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) -split '\r?\n'
        $outputLines | Where-Object {
                $_ -match '^(enabled-or-completed|pending-or-failed) hr=0x[0-9a-f]+$' -or
                $_ -match '^tsf-absence stage=[a-z-]+ hr=0x[0-9a-f]+$' -or
                $_ -match '^tsf-profile type=[0-9]+ lang=0x[0-9a-f]+ clsid=\{[0-9a-f-]{36}\} profile=\{[0-9a-f-]{36}\} flags=0x[0-9a-f]+$' -or
                $_ -match '^tsf-[a-z0-9-]+$' -or
                $_ -match '^PASS ' -or $_ -eq 'ready'
            } | ForEach-Object { Write-Output $_ }
        if ($process.ExitCode -ne $Expected) {
            if ($WarnOnProfileRemains -and $Expected -eq 0 -and (Test-RimeQProfileResidual $action $process.ExitCode $outputLines)) {
                Write-Output '::warning title=Windows TSF profile remains::Windows still enumerates a Rime Q profile after unregistering its components (0x80004005). TSF profile absence is not confirmed; see the profile diagnostics.'
                return
            }
            $log = Join-Path $env:ProgramFiles 'RimeQ\installation.log'
            if (Test-Path -LiteralPath $log) {
                Get-Content -LiteralPath $log -Tail 20 | Where-Object { $_ -match '^[^ ]+ build=[0-9.]+ pid=[0-9]+ state=[a-z0-9-]+$' } | ForEach-Object { Write-Output $_ }
            }
            throw "Unexpected Rime Q exit code for ${label}: $($process.ExitCode), expected $Expected"
        }
        Write-Output "PASS lifecycle command: $label (exit $Expected)"
    } finally { $process.Dispose() }
}
