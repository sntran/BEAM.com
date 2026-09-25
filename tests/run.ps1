# Run beam.com and greeter.com on Windows, and check what they print.
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
$fail = 0

function Check($Name, $Pattern, [string[]]$Arguments) {
    Write-Host "==> $Name"
    # Windows runs an APE file as a PE executable. Use an .exe name.
    $exe = Join-Path $Dir ($Name -replace '\.com$', '.exe')
    Copy-Item (Join-Path $Dir $Name) $exe -Force
    $out = & $exe @Arguments 2>&1 | Out-String
    $rc = $LASTEXITCODE
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
