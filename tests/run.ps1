# Run beam.com and the example programs on Windows, and check what they
# print. Run it from the top of the repository to also test
# "beam.com INPUT -o OUTPUT".
# Usage: tests/run.ps1 DIR
param([string]$Dir = ".")
# An absolute path: some checks run in another directory.
$Dir = (Resolve-Path $Dir).Path
# The time limit of each check, in seconds (a slow build sets more).
$script:Limit = 120
$fail = 0
$failures = [System.Collections.Generic.List[string]]::new()

# Check NAME PATTERN ARGUMENTS [EXPECT] [-Net]: run the program NAME of
# DIR with ARGUMENTS, and check its exit status and its output
# (CheckOnce). With -Net (as net_check of tests/run.sh), the check uses
# the network: a failure gets two more tries, after 10 s and after 30 s,
# and the log shows each try.
function Check($Name, $Pattern, [string[]]$Arguments, [int]$Expect = 0, [switch]$Net) {
    for ($try = 1; ; $try++) {
        $script:pending = [System.Collections.Generic.List[string]]::new()
        CheckOnce $Name $Pattern $Arguments $Expect
        if ($script:pending.Count -eq 0) { return }
        if ($Net -and $try -lt 3) {
            $wait = $try * 20 - 10
            Write-Host "RETRY: $Name uses the network: try $($try + 1) of 3 in $wait s"
            Start-Sleep -Seconds $wait
            continue
        }
        $script:fail = 1
        $script:pending | ForEach-Object { $script:failures.Add($_) }
        return
    }
}

# CheckOnce: one try of Check. It adds each failure to $script:pending.
function CheckOnce($Name, $Pattern, [string[]]$Arguments, [int]$Expect) {
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

    $timedOut = -not $p.WaitForExit($script:Limit * 1000)
    if ($timedOut) {
        Write-Host "FAIL: $Name did not stop in $($script:Limit) seconds. Processes:"
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
        Write-Host "FAIL: $Name exited with $rc (expected $Expect)"
        $script:pending.Add("$Name $($Arguments -join ' '): exited with $rc (expected $Expect)`n$tail")
    } else {
        # The patterns are separated by "@@". Each one must be found.
        $ok = $true
        foreach ($pat in ($Pattern -split '@@')) {
            if ($out -notmatch $pat) {
                Write-Host "FAIL: $Name did not print `"$pat`""
                $script:pending.Add("$Name $($Arguments -join ' '): did not print `"$pat`"`n$tail")
                $ok = $false
            }
        }
        # Kernel must accept the inetrc that BEAM.com writes on Windows.
        if ($out -match 'inet_config: syntax error') {
            Write-Host "FAIL: ${Name}: kernel did not accept the inetrc"
            $script:pending.Add("${Name}: kernel did not accept the inetrc")
            $ok = $false
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

# The writes to a non-blocking pipe (c_src/cosmo/beam_com_pipe.c), and the
# pipe of the SSH agent (c_src/cosmo/beam_com_agent.c): the build job of CI
# makes pipe_check.com and agent_check.com with cosmocc.
if (Test-Path (Join-Path $Dir "pipe_check.com")) {
    Check "pipe_check.com" '(?m)^pipe_check: ok' @()
}
if (Test-Path (Join-Path $Dir "agent_check.com")) {
    Check "agent_check.com" '(?m)^agent_check: ok' @()
}

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
        Check "$app.com" $patterns[$app] @() -Net:($app -eq "tls_check")
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
            Check "$app.b.com" $patterns[$app] @() -Net:($app -eq "tls_check")
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
    # The peer module of OTP: the program starts its own file in erl mode
    # as a port program (posix_spawn(), C16 of docs/UPSTREAM.md), then the
    # exit status of a port program, os:cmd/1 with the sh of Git, findstr
    # (a reader with large reads), a listen socket that a port program
    # must not get, the suffix .exe, a script and nouse_stdio.
    Check "beam.com" 'wrote .*peer_check.b.com' @("tests/programs/peer_check.erl", "-o", "$Dir/peer_check.b.com")
    if (Test-Path (Join-Path $Dir "peer_check.b.com")) {
        $peerLine = 'release [0-9]+, sum 6, own code true, error boom, bytes 1000000, sent 1000000'
        Check "peer_check.b.com" ("(?m)^peer standard_io: $peerLine`$@@(?m)^peer tcp: $peerLine`$@@(?m)^exit status 3`$@@(?m)^cmd hello`$@@(?m)^slow reader 200000`$" +
            '@@(?m)^native reader true$@@(?m)^closed listen socket refused$@@(?m)^find executable true$@@(?m)^script ok$@@(?m)^nouse_stdio fd ping$') @()
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

# The sandbox (--allow-*) on Windows (c_src/cosmo/beam_com_fs.c): the
# check of the paths, no network without net, and a job object of one
# process without run. The host list of --allow-net works on Windows too
# (see below).
if (Test-Path "examples") {
    Check "beam.com" '--allow-net: a bad domain' @("tests/programs/sandbox_check.erl", "--allow-net=*.com", "-o", "$Dir/never.com") 1
    Check "beam.com" 'wrote .*sandbox_net.com' @("tests/programs/sandbox_check.erl", "-N", "--allow-read=/etc", "-o", "$Dir/sandbox_net.com")
    if (Test-Path (Join-Path $Dir "sandbox_net.com")) {
        Remove-Item (Join-Path $Dir "sandbox.tmp") -ErrorAction SilentlyContinue
        Check "sandbox_net.com" 'a job object of one process@@read: error eacces@@write: error eacces@@listen: ok@@done' @("read", "$Dir/beam.com", "write", "$Dir/sandbox.tmp", "listen")
    }
    # A directory of --allow-write, with another case of the name. ".."
    # leaves it, and Windows reads ".. " as "..", so the check refuses it.
    $rw = Join-Path $Dir "sandbox-w"
    Remove-Item $rw -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $rw | Out-Null
    Check "beam.com" 'wrote .*sandbox_rw.com' @("tests/programs/sandbox_check.erl", "--allow-write=$rw", "-o", "$Dir/sandbox_rw.com")
    if (Test-Path (Join-Path $Dir "sandbox_rw.com")) {
        Check "sandbox_rw.com" 'a job object of one process@@read: error eacces@@write: ok@@write: ok@@write: error eacces@@write: error eacces@@listen: error eacces@@done' `
            @("read", "$Dir/beam.com", "write", "$rw/new.txt", "write", ($rw.ToUpper() + "\upper.txt"),
              "write", "$rw/../sandbox.tmp", "write", "$rw/.. /sandbox.tmp", "listen")
    }
    Remove-Item $rw -Recurse -Force -ErrorAction SilentlyContinue
}

# --allow-net=HOST,...: the resolver of beam.com and the check of each
# address, with the name server of tests/programs/dns_fake.erl (see
# tests/run.sh). A name that the list does not allow never goes to the
# name server.
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*dns_fake.com' @("tests/programs/dns_fake.erl", "-o", "$Dir/dns_fake.com")
    Check "beam.com" 'wrote .*sandbox_none.com' @("tests/programs/sandbox_check.erl", "-o", "$Dir/sandbox_none.com")
    if ((Test-Path (Join-Path $Dir "dns_fake.com")) -and (Test-Path (Join-Path $Dir "sandbox_none.com"))) {
        $fakeExe = Join-Path $Dir "dns_fake.exe"
        Copy-Item (Join-Path $Dir "dns_fake.com") $fakeExe -Force
        $fakeOut = Join-Path $Dir "dns_fake.out"
        $fake = Start-Process -FilePath (Resolve-Path $fakeExe).Path -PassThru -NoNewWindow `
            -RedirectStandardOutput $fakeOut -RedirectStandardError "$fakeOut.err"
        $ports = $null
        for ($i = 0; $i -lt 30 -and -not $ports; $i++) {
            Start-Sleep -Seconds 1
            $m = Select-String -Path $fakeOut -Pattern '^dns_fake: (\d+) (\d+)$' -ErrorAction SilentlyContinue
            if ($m) { $ports = $m.Matches[0].Groups }
        }
        if ($ports) {
            $dns = $ports[1].Value
            $tcp = $ports[2].Value
            $env:BEAM_COM_ALLOW = "net=*.test.example:$tcp"
            $env:BEAM_COM_DNS_UPSTREAM = "127.0.0.1:$dns"
            Check "sandbox_none.com" 'connect a.test.example: ok@@connect big.test.example: ok@@connect alias.test.example: ok@@connect test.example: error nxdomain@@connect other.example: error nxdomain@@connect a.test.example: error eacces@@connect 127.0.0.2: error eacces@@udp 127.0.0.1: error eacces@@done' `
                @("connect", "a.test.example", $tcp, "connect", "big.test.example", $tcp,
                  "connect", "alias.test.example", $tcp, "connect", "test.example", $tcp,
                  "connect", "other.example", $tcp, "connect", "a.test.example", $dns,
                  "connect", "127.0.0.2", $tcp, "udp", "127.0.0.1", $dns)
            Remove-Item Env:BEAM_COM_ALLOW, Env:BEAM_COM_DNS_UPSTREAM
        }
        Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
        $asked = @(Get-Content $fakeOut -ErrorAction SilentlyContinue)
        $asked | Write-Host
        if (-not $ports -or ($asked -match 'asked (other|test)\.example$') -or
            -not ($asked -match 'asked a\.test\.example$')) {
            Write-Host "FAIL: dns_fake.com: the names that the resolver asked"
            $script:fail = 1
            $failures.Add("dns_fake.com: the names that the resolver asked")
        } else {
            Write-Host "PASS: dns_fake.com"
        }
    }
}

# The claims of docs/SANDBOX.md (tests/sandbox_claims.txt), with the
# column of Windows: see tests/run.sh. Check runs the program as
# sandbox_none.exe, so that is its own file ($SELF).
if ((Test-Path "examples") -and (Test-Path (Join-Path $Dir "sandbox_none.com"))) {
    $claims = Join-Path $Dir "claims"
    $self = Join-Path $Dir "sandbox_none.exe"
    foreach ($row in Get-Content "tests/sandbox_claims.txt") {
        if ($row -match '^#' -or $row.Trim() -eq '') { continue }
        $f = $row -split ' \| '
        if ($f.Count -ne 9) {
            Write-Host "FAIL: tests/sandbox_claims.txt: a line without 9 fields: $row"
            $script:fail = 1
            $failures.Add("tests/sandbox_claims.txt: a line without 9 fields")
            continue
        }
        Write-Host "--- claim: $($f[0])"
        $want = $f[6]
        if ($want -eq '-') {
            Write-Host "SKIP: not on this system"
            continue
        }
        Remove-Item $claims -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory "$claims/in/sub", "$claims/in/d", "$claims/out/d" | Out-Null
        Set-Content "$claims/in/a.txt" "a"
        Set-Content "$claims/in/sub/b.txt" "b"
        Set-Content "$claims/out/a.txt" "a"
        $allow = $f[1].Replace('$IN', "$claims/in").Replace('$OUT', "$claims/out")
        $words = @($f[2].Replace('$IN', "$claims/in").Replace('$OUT', "$claims/out").Replace('$SELF', $self) -split ' ')
        $name = $words[0]
        if ($name -eq 'run') { $name = "run $($words[1])" }
        $env:BEAM_COM_ALLOW = $allow
        Check "sandbox_none.com" "(?m)^${name}: $want`r?$" $words
        Remove-Item Env:BEAM_COM_ALLOW
    }
    Remove-Item $claims -Recurse -Force -ErrorAction SilentlyContinue
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
    # A project that needs Mix (config/runtime.exs): a child beam.com runs
    # the Mix steps, as a port program (C16 of docs/UPSTREAM.md).
    Check "beam.com" 'Mix gets the deps of tests/programs/runtime_check and makes its release \(config/runtime.exs\)@@wrote .*runtime_check.com@@applications: .*runtime_check' @("tests/programs/runtime_check", "-o", "$Dir/runtime_check.com")
    Remove-Item "tests/programs/runtime_check/_build" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $Dir "runtime_check.com")) {
        $env:RUNTIME_CHECK_GREETING = "hello from config/runtime.exs"
        Check "runtime_check.com" 'runtime_check: hello from config/runtime.exs@@runtime_check: build from config/config.exs' @()
        Remove-Item Env:RUNTIME_CHECK_GREETING
    }
}

# The tools (see tests/run.sh), as the first argument of beam.com, and
# by the name of the file (mix.com, elixir.com: hard links to beam.com,
# as a copy).
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
# Phoenix (see tests/run.sh): a new app with no database, in one file
# with no Mix task first, and the start page and the digested CSS of the
# file. On Windows, the builder chooses the programs of tailwind and
# esbuild for Windows (beam_com_mix), git.exe gets the git deps, and
# the release has the priv of the app through a link to a directory
# (C54 of docs/UPSTREAM.md).
function PhoenixCheck {
    $phx = Join-Path ([System.IO.Path]::GetTempPath()) ("beam_com_phx_" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $phx | Out-Null
    Push-Location $phx
    Check "mix.com" 'hex' @("local.hex", "--force") -Net
    Check "mix.com" 'phx_new' @("archive.install", "hex", "phx_new", "--force") -Net
    Check "mix.com" 'creating hello/mix.exs' @("phx.new", "hello", "--no-ecto", "--no-install")
    $out = Join-Path $Dir "hello.com"
    if (Test-Path "hello") {
        Set-Location hello
        # Mix gets and compiles the deps, and downloads the asset programs.
        $script:Limit = 900
        Check "beam.com" ('Mix gets the deps of \. and makes its release \(config/runtime.exs, deps that are not Hex packages: heroicons daisyui' +
            '@@tailwind for Windows \(target windows-x64.exe\)@@esbuild for Windows: .*esbuild-win32-x64-.*\.exe' +
            '@@Check your digested files@@wrote .*hello.com@@applications: .*hello .*phoenix') @(".", "-o", $out) -Net
        $script:Limit = 120
    }
    Pop-Location
    if (Test-Path $out) { PhoenixServe $out }
    Remove-Item -Recurse -Force $phx -ErrorAction SilentlyContinue
}

# PhoenixServe FILE: start the release in FILE, and get its start page
# and the digested CSS of the page. The endpoint of a new app listens on
# the IPv6 address "::", and on Windows such a socket gets no IPv4
# connection (IPV6_V6ONLY). Thus the check uses localhost (::1).
function PhoenixServe($File) {
    Write-Host "==> hello.com"
    $exe = $File -replace '\.com$', '.exe'
    Copy-Item $File $exe -Force
    $env:PHX_SERVER = "true"
    $env:PORT = "4124"
    $env:SECRET_KEY_BASE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    $log = "$exe.log"
    $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    Remove-Item Env:PHX_SERVER, Env:PORT, Env:SECRET_KEY_BASE
    $page = $null
    for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -UseBasicParsing http://localhost:4124/ -TimeoutSec 5
            if ($r.Content -match 'Phoenix Framework') { $page = $r.Content; break }
        } catch { }
    }
    $css = if ($page) { [regex]::Match($page, '/assets/css/app-[0-9a-f]+\.css[^"]*').Value } else { "" }
    $code = 0
    if ($css) {
        try { $code = (Invoke-WebRequest -UseBasicParsing "http://localhost:4124$css" -TimeoutSec 10).StatusCode } catch { }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    if ($page -and $code -eq 200) {
        Write-Host "PASS: hello.com serves the start page and $css (after $i s)"
    } else {
        Get-Content $log, "$log.err" -Tail 20 -ErrorAction SilentlyContinue | Write-Host
        Write-Host "FAIL: hello.com did not serve the start page and its digested CSS"
        $script:fail = 1
        $script:failures.Add("hello.com: no start page or digested CSS on http://localhost:4124/ (CSS: '$css', status $code)")
    }
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
    if (Test-Path "examples") { PhoenixCheck }
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

# NIF libraries in WebAssembly (docs/NIFS.md), as in run.sh: the AOT file
# or the .wasm, then the interpreter (BEAM_COM_NIF_AOT=0).
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*nif_check.com' @("tests/programs/nif_check", "--main", "nif_check", "-o", "$Dir/nif_check.com")
    if (Test-Path (Join-Path $Dir "nif_check.com")) {
        $env:BEAM_COM_NIF_DEBUG = "1"
        Check "nif_check.com" 'nif_wasm: .*nif_check\.(x86_64\.aot|wasm)@@nif_check: all [0-9]+ passed' @()
        $env:BEAM_COM_NIF_AOT = "0"
        Check "nif_check.com" 'nif_wasm: .*nif_check\.wasm@@nif_check: all [0-9]+ passed' @()
        Remove-Item Env:BEAM_COM_NIF_DEBUG, Env:BEAM_COM_NIF_AOT
    }
}

# Native NIF objects (docs/NIFS.md), as in run.sh: load_nif/2 loads
# priv/native_nif_check.x86_64.o from the zip of the program. On Windows the
# loader also changes the TLS instructions of the object (the TLS slot of
# the thread).
if (Test-Path "examples") {
    Check "beam.com" 'wrote .*native_nif_check.com' @("tests/programs/native_nif_check", "--main", "native_nif_check", "-o", "$Dir/native_nif_check.com")
    if (Test-Path (Join-Path $Dir "native_nif_check.com")) {
        $env:BEAM_COM_NIF_DEBUG = "1"
        Check "native_nif_check.com" 'nif_native: .*native_nif_check\.x86_64\.o@@native_nif_check: all [0-9]+ passed' @()
        Remove-Item Env:BEAM_COM_NIF_DEBUG
    }
}

# Assemble OUT BASE COUNT SPECS: OUT from BASE and the COUNT files of the
# specs (NAME=FILE, or PREFIX/=DIR for each file of DIR), with
# scripts/assemble.erl, as in tests/run.sh.
function Assemble($Out, $Base, $Count, [string[]]$Specs) {
    $leaf = Split-Path $Out -Leaf
    Check "beam.com" "(?m)assemble: wrote .*$([regex]::Escape($leaf)): [0-9]+ bytes, the length of the start; new files: $Count\r?$" (@("scripts/assemble.erl", "--", $Base, $Out) + $Specs)
}

# The count of the regular files of each directory.
function FileCount([string[]]$Dirs) {
    return @(Get-ChildItem -Recurse -File $Dirs).Count
}

# The NIFs of the store as native NIF objects (tests/run.sh): vix,
# rusty_csv and ex_pdfium, from store_nifs.tar.gz of CI, with
# nif_needs.com.
$StoreNifs = Join-Path $Dir "store_nifs.tar.gz"
if ((Test-Path "examples") -and (Test-Path $StoreNifs)) {
    $Store = Join-Path $Dir "store_nifs"
    if (Test-Path $Store) { Remove-Item -Recurse -Force $Store }
    New-Item -ItemType Directory -Force -Path $Store | Out-Null
    tar -xzf $StoreNifs -C $Store
    Copy-Item (Join-Path $Store "nif_needs.com") (Join-Path $Dir "nif_needs.com") -Force
    $Objects = @(Get-ChildItem -Recurse -File -Filter "*.x86_64.o" (Join-Path $Store "nifs") | Sort-Object FullName | ForEach-Object { $_.FullName })
    Check "nif_needs.com" 'libex_pdfium\.x86_64\.o: ok@@librustycsv\.x86_64\.o: ok@@vix\.x86_64\.o: ok' $Objects
    $Priv = "tests/programs/store_nif_check/priv"
    if (Test-Path $Priv) { Remove-Item -Recurse -Force $Priv }
    New-Item -ItemType Directory -Force -Path $Priv | Out-Null
    # Each file of nifs/APP-VSN, at its path in priv/ (native/ of two
    # packages goes into one directory).
    Get-ChildItem -Directory (Join-Path $Store "nifs") | ForEach-Object {
        $pkg = $_.FullName
        Get-ChildItem -Recurse -File $pkg | ForEach-Object {
            $to = Join-Path $Priv $_.FullName.Substring($pkg.Length + 1)
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            Copy-Item -Force $_.FullName $to
        }
    }
    $StoreOk = 'store_nif_check: vix ok@@store_nif_check: rustycsv ok@@store_nif_check: ex_pdfium ok@@store_nif_check: all 3 passed'
    Check "beam.com" 'wrote .*store_nif_check.com' @("tests/programs/store_nif_check", "--main", "store_nif_check", "-o", "$Dir/store_nif_check.com")
    if (Test-Path (Join-Path $Dir "store_nif_check.com")) {
        Check "store_nif_check.com" $StoreOk @()
    }
    # The same program, assembled by hand (scripts/assemble.erl): the
    # program with no objects, and then the objects as new files of its
    # zip, as a server streams it.
    $Base = Join-Path $Dir "store_nif_base"
    if (Test-Path $Base) { Remove-Item -Recurse -Force $Base }
    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    Copy-Item -Recurse "tests/programs/store_nif_check/src" $Base
    Check "beam.com" 'wrote .*store_nif_base.com' @($Base, "--main", "store_nif_check", "-o", "$Dir/store_nif_base.com")
    Assemble "$Dir/store_nif_hand.com" "$Dir/store_nif_base.com" (FileCount @($Priv)) @("lib/store_nif_check-1.0.0/priv/=$Priv")
    if (Test-Path (Join-Path $Dir "store_nif_hand.com")) {
        Check "store_nif_hand.com" $StoreOk @()
    }
    # A beam.com assembled from parts, and the Elixir programs of the
    # three packages from hex.pm (tests/run.sh).
    # The license texts of the parts (PDFium) go into licenses/.
    # parts.txt gives the files of each package ("PKG PREFIX/=DIR").
    $Specs = @()
    $PartSpecs = @()
    foreach ($line in Get-Content (Join-Path $Store "parts.txt")) {
        if (-not $line) { continue }
        $pkg, $spec = $line -split ' ', 2
        $name, $from = $spec -split '=', 2
        $Specs += "$name=$(Join-Path $Store $from)"
        $PartSpecs += "$($pkg):$name=$(Join-Path $Store $from)"
    }
    Assemble "$Dir/beam_nifs.com" "$Dir/beam.com" (FileCount @((Join-Path $Store "nifs"), (Join-Path $Store "licenses"))) $Specs
    # The same program from the segments that the FIFO beam.com streams
    # (tests/run.sh).
    $Parts = Join-Path $Dir "program_parts"
    if (Test-Path $Parts) { Remove-Item -Recurse -Force $Parts }
    Check "beam.com" 'the program of ex_pdfium\.rusty_csv\.vix has [0-9]+ bytes' (@("scripts/assemble.erl", "--", "--parts", "$Dir/beam.com", $Parts, "0123abc", "beam.com/p/") + $PartSpecs)
    foreach ($set in @("ex_pdfium.rusty_csv.vix", "rusty_csv")) {
        $joined = Join-Path $Dir "beam_p_$set.com"
        if (Test-Path $joined) { Remove-Item -Force $joined }
        $list = Join-Path $Parts "beam-p.plus.$set.txt"
        if (-not (Test-Path $list)) { continue }
        $outStream = [System.IO.File]::Create($joined)
        try {
            foreach ($url in Get-Content $list) {
                $inStream = [System.IO.File]::OpenRead((Join-Path $Parts ($url -replace '^beam\.com/p/', '')))
                try { $inStream.CopyTo($outStream) } finally { $inStream.Dispose() }
            }
        } finally { $outStream.Dispose() }
    }
    $Whole = Join-Path $Dir "beam_p_ex_pdfium.rusty_csv.vix.com"
    if ((Test-Path (Join-Path $Dir "beam_nifs.com")) -and (Test-Path $Whole) -and
        ((Get-FileHash (Join-Path $Dir "beam_nifs.com")).Hash -eq (Get-FileHash $Whole).Hash)) {
        Write-Host "PASS: the segments of ex_pdfium.rusty_csv.vix are beam_nifs.com"
    } else {
        Write-Host "FAIL: the segments of ex_pdfium.rusty_csv.vix are not beam_nifs.com"
        $script:fail = 1
        $failures.Add("assemble.erl --parts: the segments are not the bytes of beam_nifs.com")
    }
    if (Test-Path (Join-Path $Dir "beam_p_rusty_csv.com")) {
        Check "beam_p_rusty_csv.com" '(?m)NIF files   : .*rusty_csv-' @("--version")
    }
    if (Test-Path (Join-Path $Dir "beam_nifs.com")) {
        Check "beam_nifs.com" 'NIF files   : .*ex_pdfium-.* rusty_csv-.* vix-' @("--version")
        Check "beam_nifs.com" '(?m)^licenses: pdfium' @("-noshell", "-eval", 'true = filelib:is_regular("/zip/licenses/pdfium/pdfium.txt"), io:format("licenses: pdfium~n"), halt().')
        foreach ($p in @("vix_check", "rusty_csv_check", "ex_pdfium_check")) {
            $src = Join-Path $Dir $p
            if (Test-Path $src) { Remove-Item -Recurse -Force $src }
            Copy-Item -Recurse "tests/programs/$p" $src
            # A build compiles the package and its deps: more time.
            $script:Limit = 600
            Check "beam_nifs.com" "wrote .*$p.com" @($src, "-o", "$Dir/$p.com") -Net
            $script:Limit = 120
            if (Test-Path (Join-Path $Dir "$p.com")) {
                Check "$p.com" "(?m)^$($p): ok" @()
            }
        }
    }
} elseif (Test-Path "examples") {
    Write-Host "SKIP: store_nif_check.com (no $StoreNifs)"
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

# The SSH agent of Windows OpenSSH: the git client connects to its named
# pipe through ssh_agent_bridge (c_src/cosmo/beam_com_agent.c). The check
# starts the service ssh-agent (a runner of CI is an administrator), and
# adds a new key without a passphrase.
if ((Test-Path "examples") -and (Get-Service ssh-agent -ErrorAction SilentlyContinue)) {
    $agentReady = $false
    try {
        Set-Service ssh-agent -StartupType Manual -ErrorAction Stop
        Start-Service ssh-agent -ErrorAction Stop
        $agentReady = $true
    } catch {
        Write-Host "SKIP: ssh_agent_check: the service ssh-agent does not start ($_)"
    }
    if ($agentReady) {
        $key = Join-Path ([System.IO.Path]::GetTempPath()) "beam_com_agent_key"
        Remove-Item $key, "$key.pub" -ErrorAction SilentlyContinue
        & ssh-keygen.exe -q -t ed25519 -N ([string]::Empty) -C beam_com_agent_check -f $key
        & ssh-add.exe $key 2>&1 | Write-Host
        Check "beam.com" 'ssh_agent_check: [0-9]+ keys, the key signs' @("escript", "tests/programs/ssh_agent_check.escript", '\\.\pipe\openssh-ssh-agent', "$key.pub")
        & ssh-add.exe -d $key 2>&1 | Write-Host
        Remove-Item $key, "$key.pub" -ErrorAction SilentlyContinue
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
