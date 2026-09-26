# Run beam.com and greeter.com on Windows, and check what they print.
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
$fail = 0

function Check($Name, $Pattern, [string[]]$Arguments) {
    Write-Host "==> $Name"
    # Windows runs an APE file as a PE executable. Use an .exe name.
    $exe = Join-Path $Dir ($Name -replace '\.com$', '.exe')
    Copy-Item (Join-Path $Dir $Name) $exe -Force

    # Run with a time limit. Read the output line by line, so that we see
    # the output before a hang too.
    $env:BEAM_COM_VERBOSE = "1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Resolve-Path $exe).Path
    $psi.Arguments = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $handler = { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } }
    $o = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler -MessageData $lines
    $e = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action $handler -MessageData $lines
    [void]$p.Start()
    # stdin: a pipe at EOF, the same on each runner.
    $p.StandardInput.Close()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()

    $timedOut = -not $p.WaitForExit(120000)
    if ($timedOut) {
        Write-Host "FAIL: $Name did not stop in 120 seconds. Processes:"
        Get-Process | Where-Object { $_.ProcessName -match 'beam|greeter' } |
            Format-Table Id, ProcessName, StartTime -AutoSize | Out-String | Write-Host
        $p.Kill($true)
        Get-Process | Where-Object { $_.ProcessName -match 'beam|greeter' } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $left = Get-Process | Where-Object { $_.ProcessName -match 'beam|greeter' }
    if ($left) {
        Write-Host "Processes still running after $Name stopped:"
        $left | Format-Table Id, ProcessName, StartTime -AutoSize | Out-String | Write-Host
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Unregister-Event -SourceIdentifier $o.Name
    Unregister-Event -SourceIdentifier $e.Name
    $out = ($lines.ToArray() -join "`n")
    $rc = if ($timedOut) { 124 } else { $p.ExitCode }
    Write-Host $out
    if ($rc -ne 0) {
        Write-Host "FAIL: $Name exited with $rc"; $script:fail = 1
    } else {
        # The patterns are separated by "@@". Each one must be found.
        $ok = $true
        foreach ($pat in ($Pattern -split '@@')) {
            if ($out -notmatch $pat) {
                Write-Host "FAIL: $Name did not print `"$pat`""
                $ok = $false; $script:fail = 1
            }
        }
        if ($ok) { Write-Host "PASS: $Name" }
    }
}

Check "beam.com" 'Arguments   : \["hello","world"\]' @("hello", "world")
if (Test-Path (Join-Path $Dir "greeter.com")) {
    Check "greeter.com" 'said hello 3 times' @()
}
if (Test-Path (Join-Path $Dir "crypto_check.com")) {
    Check "crypto_check.com" ('sha256\(abc\) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' +
        '@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0' +
        '@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello') @()
}
if (Test-Path (Join-Path $Dir "tls_check.com")) {
    # "verify peer, N OS certificates": the roots of Windows were exported.
    Check "tls_check.com" 'ports: not supported on windows@@tls: local handshake ok@@tls: remote [^ ]* ok \([^)]*verify peer, [0-9]+ OS certificates\)' @()
}
exit $fail
