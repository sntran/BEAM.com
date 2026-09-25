# Run beam.com and greeter.com on Windows, and check what they print.
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
$fail = 0

function Check($Name, $Pattern, [string[]]$Arguments) {
    Write-Host "==> $Name"
    # Windows runs an APE file as a PE executable. Use an .exe name.
    $exe = Join-Path $Dir ($Name -replace '\.com$', '.exe')
    Copy-Item (Join-Path $Dir $Name) $exe -Force
    # Run with a time limit, and capture stdout and stderr.
    $env:BEAM_COM_VERBOSE = "1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Resolve-Path $exe).Path
    $psi.Arguments = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) {
        $p.Kill($true)
        Write-Host "FAIL: $Name did not stop in 120 seconds"
        Get-Process | Where-Object { $_.ProcessName -match 'beam|greeter' } | Format-Table -AutoSize
    }
    $p.WaitForExit()
    $out = $stdout.Result + $stderr.Result
    $rc = $p.ExitCode
    Write-Host $out
    if ($rc -ne 0) {
        Write-Host "FAIL: $Name exited with $rc"; $script:fail = 1
    } elseif ($out -notmatch $Pattern) {
        Write-Host "FAIL: $Name did not print `"$Pattern`""; $script:fail = 1
    } else {
        Write-Host "PASS: $Name"
    }
}

Check "beam.com" 'Arguments   : \["hello","world"\]' @("hello", "world")
if (Test-Path (Join-Path $Dir "greeter.com")) {
    Check "greeter.com" 'said hello 3 times' @()
}
exit $fail
