# Run beam.com and the example programs on Windows, and check what they
# print. Run it from the top of the repository to also test
# "beam.com build".
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
        # Kernel must accept the inetrc that BEAM.com writes on Windows.
        if ($out -match 'inet_config: syntax error') {
            Write-Host "FAIL: ${Name}: kernel did not accept the inetrc"
            $ok = $false; $script:fail = 1
        }
        if ($ok) { Write-Host "PASS: $Name" }
    }
}

$patterns = @{
    "greeter" = 'said hello 3 times'
    "crypto_check" = ('sha256\(abc\) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' +
        '@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0' +
        '@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello')
    # "verify peer, N OS certificates": the roots of Windows were exported.
    "tls_check" = 'ports: not supported on windows@@tls: local handshake ok@@tls: remote [^ ]* ok \([^)]*verify peer, [0-9]+ OS certificates\)'
}
$apps = @("greeter", "crypto_check", "tls_check")

Check "beam.com" 'Arguments   : \["hello","world"\]' @("hello", "world")

# Releases made with rebar3 and added with zip (by CI).
foreach ($app in $apps) {
    if (Test-Path (Join-Path $Dir "$app.com")) {
        Check "$app.com" $patterns[$app] @()
    }
}

# beam.com build, on this system: the examples of the repository.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*hashsum.b.com' @("build", "examples/hashsum.erl", "-o", "$Dir/hashsum.b.com")
    if (Test-Path (Join-Path $Dir "hashsum.b.com")) {
        Check "hashsum.b.com" '(?m)^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$' @("abc")
    }
    foreach ($app in $apps) {
        Check "beam.com" "wrote .*$app.b.com" @("build", "examples/$app", "-o", "$Dir/$app.b.com")
        if (Test-Path (Join-Path $Dir "$app.b.com")) {
            Check "$app.b.com" $patterns[$app] @()
        }
    }
}
# WebAssembly: wasm_check, and a WASI program in Go (made by CI).
$wasm = 'wasm: add\(40, 2\) = 42@@wasm: trap: @@wasm: memory ok@@hello from wasi@@wasm: wasi exit code 7'
$go = 'go: hello from wasip1, args \[one two\]@@go: BEAM_COM=1@@go: read back "written by go"@@exited with 0'
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*wasm_check.b.com' @("build", "examples/wasm_check.erl", "-o", "$Dir/wasm_check.b.com")
    if (Test-Path (Join-Path $Dir "wasm_check.b.com")) {
        Check "wasm_check.b.com" $wasm @()
        if (Test-Path (Join-Path $Dir "hello_go.wasm")) {
            Check "wasm_check.b.com" $go @("$Dir/hello_go.wasm", "one", "two")
        }
    }
}

# The SQLite probe: beam-sqlite.com (built with SQLITE=1).
$sqlite = 'sqlite: version 3@@sqlite: json \["alpha","beta","gamma"\]@@sqlite: 3 rows in '
if ((Test-Path "examples") -and (Test-Path (Join-Path $Dir "beam-sqlite.com"))) {
    Check "beam-sqlite.com" 'wrote .*sqlite_check.b.com' @("build", "examples/sqlite_check.erl", "-o", "$Dir/sqlite_check.b.com")
    if (Test-Path (Join-Path $Dir "sqlite_check.b.com")) {
        Check "sqlite_check.b.com" ($sqlite + ':memory:') @()
        Remove-Item (Join-Path $Dir "test.db") -ErrorAction SilentlyContinue
        Check "sqlite_check.b.com" ($sqlite + [regex]::Escape("$Dir/test.db")) @("$Dir/test.db")
    }
}
exit $fail
