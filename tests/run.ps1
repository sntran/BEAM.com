# Run beam.com and the example programs on Windows, and check what they
# print. Run it from the top of the repository to also test
# "beam.com build".
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
$fail = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Check($Name, $Pattern, [string[]]$Arguments, [int]$Expect = 0) {
    Write-Host "==> $Name"
    # Windows runs an APE file as a PE executable. Use an .exe name.
    $exe = Join-Path $Dir ($Name -replace '\.com$', '.exe')
    Copy-Item (Join-Path $Dir $Name) $exe -Force

    # Run with a time limit. Read the output line by line, so that we see
    # the output before a hang too.
    $env:BEAM_COM_VERBOSE = "1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Resolve-Path $exe).Path
    # Quote the arguments with spaces or quotes (the rules of
    # CommandLineToArgvW).
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    # BEAM.com writes UTF-8.
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
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
    if ($rc -ne $Expect) {
        Write-Host "FAIL: $Name exited with $rc (expected $Expect)"; $script:fail = 1
        $script:failures.Add("$Name $($Arguments -join ' '): exited with $rc (expected $Expect)")
    } else {
        # The patterns are separated by "@@". Each one must be found.
        $ok = $true
        foreach ($pat in ($Pattern -split '@@')) {
            if ($out -notmatch $pat) {
                Write-Host "FAIL: $Name did not print `"$pat`""
                $script:failures.Add("$Name $($Arguments -join ' '): did not print `"$pat`"")
                $ok = $false; $script:fail = 1
            }
        }
        # Kernel must accept the inetrc that BEAM.com writes on Windows.
        if ($out -match 'inet_config: syntax error') {
            Write-Host "FAIL: ${Name}: kernel did not accept the inetrc"
            $script:failures.Add("${Name}: kernel did not accept the inetrc")
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

# The commands of the default beam.com.
Check "beam.com" 'usage: beam.com COMMAND@@build INPUT@@version' @()
Check "beam.com" 'usage: beam.com COMMAND' @("help")
Check "beam.com" 'usage: beam.com build INPUT' @("help", "build")
Check "beam.com" 'Erlang/OTP  : 29\.@@OS type     : unix/windows@@Emulator    : emu@@stdlib-@@esqlite-@@wasm-' @("version")
Check "beam.com" 'unknown command nosuch \(see beam.com help\)' @("nosuch") 1
# The --strace flag of the Cosmopolitan runtime (README, "Debugging").
Check "beam.com" 'SYS @@Erlang/OTP  : ' @("--strace", "version")

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
# One-file programs (beam_com_script) and the command line of beam.com.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*script_check.b.com' @("build", "tests/programs/script_check.erl", "-o", "$Dir/script_check.b.com")
    if (Test-Path (Join-Path $Dir "script_check.b.com")) {
        Check "script_check.b.com" '(?m)argc 4@@(?m)^arg a$@@(?m)^arg b c$@@(?m)^arg é$@@(?m)^arg 日本$' @("args", "a", "b c", "é", "日本")
        Check "script_check.b.com" '(?m)argc 4@@(?m)^arg \+S$@@(?m)^arg 1$@@(?m)^arg -extra$@@(?m)^arg x$' @("args", "+S", "1", "-extra", "x")
        Check "script_check.b.com" 'returning' @("return")
        Check "script_check.b.com" 'raising@@exception error: \{boom,42\}' @("raise") 127
        Check "script_check.b.com" 'exception throw: thrown_value' @("throw") 127
        Check "script_check.b.com" 'exception exit: normal' @("exit") 127
        Check "script_check.b.com" 'halting 3' @("halt", "3") 3
        Check "script_check.b.com" '(?m)^line 100000$@@(?m)^last line$' @("big")
        Check "script_check.b.com" 'returned' @("spawn")
        $env:ERL_FLAGS = "+S 1"
        Check "script_check.b.com" '(?m)^schedulers 1$' @("info")
        Remove-Item Env:ERL_FLAGS
    }
    Check "beam.com" 'usage: beam.com build INPUT' @("build") 1
    Check "beam.com" 'none.erl: no such file' @("build", "none.erl") 1
    Check "beam.com" 'unknown option -z' @("build", "x.erl", "-z") 1
    Check "beam.com" 'option -o needs a value' @("build", "x.erl", "-o") 1
    Check "beam.com" 'the application nosuch is not in beam.com' @("build", "examples/hashsum.erl", "-a", "nosuch", "-o", "$Dir/never.com") 1
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

# The behavior tests of the wasm application.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*wasm_tests.b.com' @("build", "tests/programs/wasm_tests.erl", "-o", "$Dir/wasm_tests.b.com")
    if (Test-Path (Join-Path $Dir "wasm_tests.b.com")) {
        Check "wasm_tests.b.com" 'wasm_tests: all [0-9]+ passed' @()
    }
}

# The JIT: beam-jit.com has the x86 and the arm backend.
if (Test-Path (Join-Path $Dir "beam-jit.com")) {
    Check "beam-jit.com" 'Emulator    : jit@@OS type     : unix/windows' @("version")
    if (Test-Path "examples") {
        Check "beam-jit.com" 'wrote .*hashsum.jit.com' @("build", "examples/hashsum.erl", "-o", "$Dir/hashsum.jit.com")
        if (Test-Path (Join-Path $Dir "hashsum.jit.com")) {
            Check "hashsum.jit.com" '(?m)^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$' @("abc")
        }
        Check "beam-jit.com" 'wrote .*greeter.jit.com' @("build", "examples/greeter", "-o", "$Dir/greeter.jit.com")
        if (Test-Path (Join-Path $Dir "greeter.jit.com")) {
            Check "greeter.jit.com" $patterns["greeter"] @()
        }
        Check "beam-jit.com" 'wrote .*wasm_tests.jit.com' @("build", "tests/programs/wasm_tests.erl", "-o", "$Dir/wasm_tests.jit.com")
        if (Test-Path (Join-Path $Dir "wasm_tests.jit.com")) {
            Check "wasm_tests.jit.com" 'wasm_tests: all [0-9]+ passed' @()
        }
        Check "beam-jit.com" 'wrote .*script_check.jit.com' @("build", "tests/programs/script_check.erl", "-o", "$Dir/script_check.jit.com")
        if (Test-Path (Join-Path $Dir "script_check.jit.com")) {
            Check "script_check.jit.com" '(?m)argc 2@@(?m)^arg b c$@@(?m)^arg 日本$' @("args", "b c", "日本")
            Check "script_check.jit.com" 'exception error: \{boom,42\}' @("raise") 127
            Check "script_check.jit.com" 'halting 3' @("halt", "3") 3
            Check "script_check.jit.com" '(?m)^line 100000$@@(?m)^last line$' @("big")
        }
        Check "beam-jit.com" 'wrote .*crypto_check.jit.com' @("build", "examples/crypto_check", "-o", "$Dir/crypto_check.jit.com")
        if (Test-Path (Join-Path $Dir "crypto_check.jit.com")) {
            Check "crypto_check.jit.com" $patterns["crypto_check"] @()
        }
    }
}

# SQLite (in beam.com).
$sqlite = 'sqlite: version 3@@sqlite: json \["alpha","beta","gamma"\]@@sqlite: 3 rows in '
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*sqlite_check.b.com' @("build", "examples/sqlite_check.erl", "-o", "$Dir/sqlite_check.b.com")
    if (Test-Path (Join-Path $Dir "sqlite_check.b.com")) {
        Check "sqlite_check.b.com" ($sqlite + ':memory:') @()
        Remove-Item (Join-Path $Dir "test.db") -ErrorAction SilentlyContinue
        Check "sqlite_check.b.com" ($sqlite + [regex]::Escape("$Dir/test.db")) @("$Dir/test.db")
    }
    if (Test-Path (Join-Path $Dir "beam-jit.com")) {
        Check "beam-jit.com" 'wrote .*sqlite_check.jit.com' @("build", "examples/sqlite_check.erl", "-o", "$Dir/sqlite_check.jit.com")
        if (Test-Path (Join-Path $Dir "sqlite_check.jit.com")) {
            Check "sqlite_check.jit.com" ($sqlite + ':memory:') @()
        }
    }
}
if ($fail -ne 0) {
    Write-Host "==> Failed checks:"
    $failures | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "==> All checks passed"
}
exit $fail
