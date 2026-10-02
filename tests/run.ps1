# Run beam.com and the example programs on Windows, and check what they
# print. Run it from the top of the repository to also test
# "beam.com INPUT -o OUTPUT".
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
# An absolute path: some checks run in another directory.
$Dir = (Resolve-Path $Dir).Path
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
    # The directory of Push-Location and Set-Location (the process keeps
    # its own working directory).
    $psi.WorkingDirectory = (Get-Location).ProviderPath
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
    $all = $lines.ToArray()
    $out = ($all -join "`n")
    $rc = if ($timedOut) { 124 } else { $p.ExitCode }
    # A long output is shortened in the log (the log of CI keeps only its
    # end); the checks read the whole output.
    if ($all.Count -gt 200) {
        Write-Host (($all | Select-Object -First 40) -join "`n")
        Write-Host "... ($($all.Count) lines) ..."
        Write-Host (($all | Select-Object -Last 40) -join "`n")
    } else {
        Write-Host $out
    }
    # The end of the output of a failed check, for the summary.
    $tail = (($all | Select-Object -Last 15) | ForEach-Object { "      | $_" }) -join "`n"
    if ($rc -ne $Expect) {
        Write-Host "FAIL: $Name exited with $rc (expected $Expect)"; $script:fail = 1
        $script:failures.Add("$Name $($Arguments -join ' '): exited with $rc (expected $Expect)`n$tail")
    } else {
        # The patterns are separated by "@@". Each one must be found.
        $ok = $true
        foreach ($pat in ($Pattern -split '@@')) {
            if ($out -notmatch $pat) {
                Write-Host "FAIL: $Name did not print `"$pat`""
                $script:failures.Add("$Name $($Arguments -join ' '): did not print `"$pat`"`n$tail")
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
$patterns["calc"] = '(?m)calc: 1 \+ 2 \* \(3 - 1\) - 8 / 4 = 3\r?$@@(?m)calc: asn1 ber 300980044245414d810103\r?$@@(?m)calc: asn1 decoded BEAM 3\r?$'
$apps = @("greeter", "crypto_check", "tls_check")

# The commands of the default beam.com.
# With no input, beam.com runs the project in the current directory. The
# top of the repository is a Mix project, so this check runs in an empty
# directory.
$empty = Join-Path ([System.IO.Path]::GetTempPath()) "beam_com_empty_$PID"
New-Item -ItemType Directory -Force $empty | Out-Null
Push-Location $empty
Check "beam.com" 'run INPUT \(default: the project in this directory\)@@make an executable of INPUT' @()
Pop-Location
Remove-Item $empty -Force
Check "beam.com" 'run INPUT \(default: the project in this directory\)' @("--help")
Check "beam.com" 'Erlang/OTP  : 29\.@@OS type     : unix/windows@@Emulator    : jit@@stdlib-@@esqlite-@@wasm-' @("--version")
Check "beam.com" 'nosuch: not a .erl, .ex or .exs file, or a directory' @("nosuch") 1
Check "beam.com" 'there is no command build' @("build") 1
# The --strace flag of the Cosmopolitan runtime (README, "Debugging").
Check "beam.com" 'SYS @@Erlang/OTP  : ' @("--strace", "--version")

# Releases made with rebar3 and added with zip (by CI).
foreach ($app in $apps) {
    if (Test-Path (Join-Path $Dir "$app.com")) {
        Check "$app.com" $patterns[$app] @()
    }
}

# beam.com INPUT -o OUTPUT, on this system: an example and the check
# programs of the repository.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*hashsum.b.com' @("examples/hashsum.erl", "-o", "$Dir/hashsum.b.com")
    if (Test-Path (Join-Path $Dir "hashsum.b.com")) {
        Check "hashsum.b.com" '(?m)^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$' @("abc")
    }
    # calc is only for beam.com INPUT -o OUTPUT (it has .xrl, .yrl and ASN.1 files).
    foreach ($app in ($apps + @("calc"))) {
        $src = if ($app -eq "greeter") { "examples/$app" } else { "tests/programs/$app" }
        Check "beam.com" "wrote .*$app.b.com" @($src, "-o", "$Dir/$app.b.com")
        if (Test-Path (Join-Path $Dir "$app.b.com")) {
            Check "$app.b.com" $patterns[$app] @()
        }
    }
}
# One-file programs (beam_com_script) and the command line of beam.com.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*script_check.b.com' @("tests/programs/script_check.erl", "-o", "$Dir/script_check.b.com")
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
    # The peer module of OTP: the program starts its own file in erl mode,
    # with the standard I/O and then a TCP connection as the channel.
    Check "beam.com" 'wrote .*peer_check.b.com' @("tests/programs/peer_check.erl", "-o", "$Dir/peer_check.b.com")
    if (Test-Path (Join-Path $Dir "peer_check.b.com")) {
        $peerLine = 'release [0-9]+, sum 6, own code true, error boom, bytes 1000000'
        Check "peer_check.b.com" "(?m)^peer standard_io: $peerLine`$@@(?m)^peer tcp: $peerLine`$" @()
    }
    # A run: the executable in the cache, with the arguments after "--"
    # and the exit status of the program (no port program: also here).
    Check "beam.com" '(?m)^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$' @("examples/hashsum.erl", "--", "abc")
    Check "beam.com" '(?m)^usage: hashsum TEXT' @("examples/hashsum.erl") 2
    Check "beam.com" 'none.erl: no such file' @("none.erl") 1
    Check "beam.com" 'unknown option -z' @("x.erl", "-z") 1
    Check "beam.com" 'option -o needs a value' @("x.erl", "-o") 1
    Check "beam.com" 'the application nosuch is not in beam.com' @("examples/hashsum.erl", "-a", "nosuch", "-o", "$Dir/never.com") 1
}

# The sandbox (--allow-*): Windows ignores it, so each action works; the
# flags must still be accepted and checked.
if (Test-Path "examples") {
    Check "beam.com" '--allow-net takes no hosts' @("tests/programs/sandbox_check.erl", "--allow-net=example.com", "-o", "$Dir/never.com") 1
    Check "beam.com" 'wrote .*sandbox_net.com' @("tests/programs/sandbox_check.erl", "-N", "--allow-read=/etc", "-o", "$Dir/sandbox_net.com")
    if (Test-Path (Join-Path $Dir "sandbox_net.com")) {
        Remove-Item (Join-Path $Dir "sandbox.tmp") -ErrorAction SilentlyContinue
        Check "sandbox_net.com" 'read: ok@@write: ok@@listen: ok@@done' @("read", "$Dir/beam.com", "write", "$Dir/sandbox.tmp", "listen")
    }
}

# Hex packages (from hex.pm, so this needs the network): see tests/run.sh.
if (Test-Path "examples") {
    Remove-Item "examples/hexweb/rebar.lock" -ErrorAction SilentlyContinue
    Check "beam.com" 'wrote .*rebar.lock@@wrote .*hexweb.com' @("examples/hexweb", "-o", "$Dir/hexweb.com")
    if (Test-Path (Join-Path $Dir "hexweb.com")) {
        Check "hexweb.com" 'hexweb: content-type application/json@@hexweb: hello BEAM.com; cowboy-[0-9.]+ cowlib-[0-9.]+ jsx-[0-9.]+ ranch-[0-9.]+' @()
    }
    Remove-Item "examples/hexweb/rebar.lock" -ErrorAction SilentlyContinue
}

# Elixir: see tests/run.sh.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*elixir_check.com' @("tests/programs/elixir_check.ex", "-o", "$Dir/elixir_check.com")
    if (Test-Path (Join-Path $Dir "elixir_check.com")) {
        Check "elixir_check.com" 'elixir: 1\.[0-9]+\.[0-9]+ on OTP 29@@args: \["a", "b c"\]@@sum: 5050@@upcase: BEAM.COM' @("a", "b c")
        Check "elixir_check.com" '\*\* \(RuntimeError\) boom' @("raise") 127
    }
    Remove-Item "examples/greeter_ex/mix.lock" -ErrorAction SilentlyContinue
    Check "beam.com" 'wrote .*greeter_ex.com' @("examples/greeter_ex", "-o", "$Dir/greeter_ex.com")
    if (Test-Path (Join-Path $Dir "greeter_ex.com")) {
        Check "greeter_ex.com" 'greeter_ex: Hello from config/config.exs \(2\)@@greeter_ex: decoded 1\.' @()
    }
    Remove-Item "examples/greeter_ex/mix.lock" -ErrorAction SilentlyContinue
}

# The tools (see tests/run.sh), as the first argument of beam.com, and
# by the name of the file (mix.com, elixir.com: hard links to beam.com,
# as a copy). No port programs here (so no Hex or rebar3).
$escript = Join-Path ([System.IO.Path]::GetTempPath()) "beam_com_tools.escript"
Set-Content -Path $escript -Encoding ascii -Value @(
    '#!/usr/bin/env escript',
    '%%! +S 1 -escript main tools_escript',
    '-module(tools_escript).',
    '-export([main/1]).',
    'main(Args) -> io:format("escript: ~p ~p~n", [Args, erlang:system_info(schedulers)]).')
Check "beam.com" 'escript: \["a","b c"\] 1' @("escript", $escript, "a", "b c")
Check "beam.com" '(?m)^55\r?$' @("elixir", "-e", "IO.puts(Enum.sum(1..10))")
foreach ($t in @("mix", "elixir")) {
    New-Item -ItemType HardLink -Path (Join-Path $Dir "$t.com") -Target (Join-Path $Dir "beam.com") -Force | Out-Null
}
if (Test-Path (Join-Path $Dir "elixir.com")) {
    Check "elixir.com" '(?m)^55\r?$' @("-e", "IO.puts(Enum.sum(1..10))")
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("beam_com_mix_" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    Check "mix.com" 'creating mix.exs' @("new", "hello")
    Set-Location hello
    Check "mix.com" '2 passed' @("test")
    Pop-Location
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Dir "mix.com"), (Join-Path $Dir "elixir.com") -ErrorAction SilentlyContinue
}

# An application with an entry (toolbox): see tests/run.sh. The priv and
# peer commands run a shell script and a port program; they are tested
# on the other systems.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*toolbox.com@@applications: beam_com_script kernel stdlib' @("examples/toolbox", "-o", "$Dir/toolbox.com")
    if (Test-Path (Join-Path $Dir "toolbox.com")) {
        Check "toolbox.com" '(?m)^toolbox: Hello, Ana\r?$' @("greet", "Ana")
        Check "toolbox.com" 'toolbox: usage: ' @("nosuch") 2
        # erl mode (BEAM_COM_ERL=1): the arguments are for erl.
        $env:BEAM_COM_ERL = "1"
        Check "toolbox.com" '(?m)^1\r?$' @("+S", "1", "-noinput", "-eval", "erlang:display(erlang:system_info(schedulers)), halt().")
        Remove-Item Env:BEAM_COM_ERL
    }
    Check "beam.com" 'wrote .*toolbox2.com' @("examples/toolbox", "--main", "toolbox_cli", "-o", "$Dir/toolbox2.com")
    Check "beam.com" 'toolbox_english does not export main/1' @("examples/toolbox", "--main", "toolbox_english", "-o", "$Dir/never.com") 1
}

# WebAssembly: wasm_check, and a WASI program in Go (made by CI).
$wasm = 'wasm: add\(40, 2\) = 42@@wasm: trap: @@wasm: memory ok@@hello from wasi@@wasm: wasi exit code 7'
$go = 'go: hello from wasip1, args \[one two\]@@go: BEAM_COM=1@@go: read back "written by go"@@exited with 0'
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*wasm_check.b.com' @("tests/programs/wasm_check.erl", "-o", "$Dir/wasm_check.b.com")
    if (Test-Path (Join-Path $Dir "wasm_check.b.com")) {
        Check "wasm_check.b.com" $wasm @()
        if (Test-Path (Join-Path $Dir "hello_go.wasm")) {
            Check "wasm_check.b.com" $go @("$Dir/hello_go.wasm", "one", "two")
        }
    }
}

# The behavior tests of the wasm application.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*wasm_tests.b.com' @("tests/programs/wasm_tests.erl", "-o", "$Dir/wasm_tests.b.com")
    if (Test-Path (Join-Path $Dir "wasm_tests.b.com")) {
        Check "wasm_tests.b.com" 'wasm_tests: all [0-9]+ passed' @()
    }
}

# The interpreter: beam-emu.com (beam.com has the JIT).
if (Test-Path (Join-Path $Dir "beam-emu.com")) {
    Check "beam-emu.com" 'Emulator    : emu@@OS type     : unix/windows' @("--version")
    if (Test-Path "examples") {
        Check "beam-emu.com" 'wrote .*hashsum.emu.com' @("examples/hashsum.erl", "-o", "$Dir/hashsum.emu.com")
        if (Test-Path (Join-Path $Dir "hashsum.emu.com")) {
            Check "hashsum.emu.com" '(?m)^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$' @("abc")
        }
        Check "beam-emu.com" 'wrote .*greeter.emu.com' @("examples/greeter", "-o", "$Dir/greeter.emu.com")
        if (Test-Path (Join-Path $Dir "greeter.emu.com")) {
            Check "greeter.emu.com" $patterns["greeter"] @()
        }
        Check "beam-emu.com" 'wrote .*wasm_tests.emu.com' @("tests/programs/wasm_tests.erl", "-o", "$Dir/wasm_tests.emu.com")
        if (Test-Path (Join-Path $Dir "wasm_tests.emu.com")) {
            Check "wasm_tests.emu.com" 'wasm_tests: all [0-9]+ passed' @()
        }
        Check "beam-emu.com" 'wrote .*script_check.emu.com' @("tests/programs/script_check.erl", "-o", "$Dir/script_check.emu.com")
        if (Test-Path (Join-Path $Dir "script_check.emu.com")) {
            Check "script_check.emu.com" '(?m)argc 2@@(?m)^arg b c$@@(?m)^arg 日本$' @("args", "b c", "日本")
            Check "script_check.emu.com" 'exception error: \{boom,42\}' @("raise") 127
            Check "script_check.emu.com" 'halting 3' @("halt", "3") 3
            Check "script_check.emu.com" '(?m)^line 100000$@@(?m)^last line$' @("big")
        }
        Check "beam-emu.com" 'wrote .*crypto_check.emu.com' @("tests/programs/crypto_check", "-o", "$Dir/crypto_check.emu.com")
        if (Test-Path (Join-Path $Dir "crypto_check.emu.com")) {
            Check "crypto_check.emu.com" $patterns["crypto_check"] @()
        }
    }
}

# SQLite (in beam.com).
$sqlite = 'sqlite: version 3@@sqlite: json \["alpha","beta","gamma"\]@@sqlite: 3 rows in '
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*sqlite_check.b.com' @("tests/programs/sqlite_check.erl", "-o", "$Dir/sqlite_check.b.com")
    if (Test-Path (Join-Path $Dir "sqlite_check.b.com")) {
        Check "sqlite_check.b.com" ($sqlite + ':memory:') @()
        Remove-Item (Join-Path $Dir "test.db") -ErrorAction SilentlyContinue
        # A relative path: the Unix VFS of SQLite takes a path with a drive
        # (D:\...) as a relative path (README, "Known limits").
        $db = (Resolve-Path -Relative $Dir) + "/test.db"
        Check "sqlite_check.b.com" ($sqlite + [regex]::Escape($db)) @($db)
    }
    if (Test-Path (Join-Path $Dir "beam-emu.com")) {
        Check "beam-emu.com" 'wrote .*sqlite_check.emu.com' @("tests/programs/sqlite_check.erl", "-o", "$Dir/sqlite_check.emu.com")
        if (Test-Path (Join-Path $Dir "sqlite_check.emu.com")) {
            Check "sqlite_check.emu.com" ($sqlite + ':memory:') @()
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
