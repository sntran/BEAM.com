#!/bin/sh
# Run beam.com and the example programs, and check what they print.
# Usage: tests/run.sh DIR   (DIR holds beam.com and, if made, the example
#                            releases). Run it from the top of the
#                            repository to also test "beam.com build".
#
# RUNNER is the command that starts an APE file (default: sh). On NetBSD
# and OpenBSD, sh stops at the NUL bytes of the APE header, so use the
# APE loader there: RUNNER=DIR/ape-x86_64.elf.
set -u
dir=${1:-.}
limit=${LIMIT:-120}
runner=${RUNNER:-sh}
tmp=${TMPDIR:-/tmp}/beam_com_test.$$
fail=0
failed=

# The processes of the tests that still run (for diagnostics).
our_processes() {
    # Zombies are left out: in a container, PID 1 may not collect them.
    ps -A -o pid,ppid,stat,command 2>/dev/null | grep -v -e grep -e '\.sh' |
        awk '$3 !~ /^Z/' | grep -e "$dir/[^ ]*\.com" -e '\.ape-' || true
}

# Called by the watchdog before it kills a program: the processes, and
# the stack traces where the system has a tool for it.
diagnose() {
    echo "--- processes"
    our_processes
    for q in "$1" $(pgrep -P "$1" 2>/dev/null); do
        if command -v sample >/dev/null 2>&1; then
            echo "--- sample $q (macOS)"
            sample "$q" 1 2>&1 | head -200
        elif command -v procstat >/dev/null 2>&1; then
            echo "--- procstat -kk $q (FreeBSD)"
            procstat -kk "$q" 2>&1 | head -100
        elif [ -d "/proc/$q/task" ]; then
            echo "--- threads of $q (Linux: name, state, wait channel)"
            for t in /proc/$q/task/*; do
                printf '%s %s %s\n' "$(cat $t/comm 2>/dev/null)" \
                    "$(awk '{print $3}' $t/stat 2>/dev/null)" \
                    "$(cat $t/wchan 2>/dev/null)"
            done | sort | uniq -c
        fi
    done
}

check() {
    name=$1 pattern=$2
    shift 2
    echo "==> $name"
    chmod +x "$dir/$name"
    # Run through $runner (sh, as a user without binfmt_misc would do
    # it). A watchdog stops it after $limit seconds.
    case $runner in sh|"") ;; *) chmod +x "$runner" ;; esac
    BEAM_COM_VERBOSE=1 $runner "$dir/$name" "$@" > "$tmp" 2>&1 &
    pid=$!
    rm -f "$tmp.diag"
    # The watchdog ends by itself when the program ends (a killed "sleep"
    # would stay behind).
    (
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt "$limit" ]; do
            sleep 1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            diagnose "$pid" > "$tmp.diag" 2>&1
            kill -9 "$pid"
        fi
    ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"
    rc=$?
    wait "$watchdog" 2>/dev/null
    # The output stays in the file: in a shell variable, a large output is
    # too long for an external printf (OpenBSD ksh). A long output is
    # shortened in the log; the checks read the whole file.
    lines=$(wc -l < "$tmp")
    if [ "$lines" -gt 200 ]; then
        head -n 40 "$tmp"
        echo "... ($lines lines) ..."
        tail -n 40 "$tmp"
    else
        cat "$tmp"
    fi
    if [ $rc -eq 137 ]; then
        echo "FAIL: $name did not stop in $limit seconds"
        cat "$tmp.diag" 2>/dev/null
    fi
    if [ "$probe" = 1 ]; then
        echo "PROBE: $name exited with $rc (not checked)"
        return
    fi
    if [ $rc -ne "$expect" ]; then
        echo "FAIL: $name exited with $rc (expected $expect)"
        failed="$failed
  $name $*: exited with $rc (expected $expect)"
        fail=1
    else
        # The patterns are separated by "@@". Each one must be found.
        ok=1
        rest=$pattern
        while [ -n "$rest" ]; do
            p=${rest%%@@*}
            case $rest in *@@*) rest=${rest#*@@} ;; *) rest= ;; esac
            if ! grep -q -e "$p" "$tmp"; then
                echo "FAIL: $name did not print \"$p\""
                failed="$failed
  $name $*: did not print \"$p\""
                ok=0
                fail=1
            fi
        done
        [ $ok -eq 1 ] && echo "PASS: $name"
    fi
}

# check_status RC NAME PATTERN ARGS...: as check, but the program must
# exit with RC.
expect=0
check_status() {
    expect=$1
    shift
    check "$@"
    expect=0
}

# probe NAME ARGS...: run as check (with the time limit), but only show
# the output and the exit status (for behavior that is not known yet).
probe=0
probe() {
    probe=1
    probe_name=$1
    shift
    check "$probe_name" '' "$@"
    probe=0
}

greeter='said hello 3 times'
crypto_check='sha256(abc) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello'
tls_check='ports: ok@@tls: local handshake ok@@tls: remote [^ ]* ok'
hashsum='^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$'
calc='calc: 1 + 2 \* (3 - 1) - 8 / 4 = 3$@@calc: asn1 ber 300980044245414d810103$@@calc: asn1 decoded BEAM 3$'

# The commands of the default beam.com. os:type() names this system.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
check beam.com 'usage: beam.com COMMAND@@build INPUT@@version'
check beam.com 'usage: beam.com COMMAND' help
check beam.com 'usage: beam.com build INPUT' help build
check beam.com "Erlang/OTP  : 29\.@@OS type     : unix/$os@@Emulator    : jit@@stdlib-@@esqlite-@@wasm-" version
check_status 1 beam.com 'unknown command nosuch (see beam.com help)' nosuch
# The --strace flag of the Cosmopolitan runtime (README, "Debugging").
check beam.com 'SYS @@Erlang/OTP  : ' --strace version

# Releases made with rebar3 and added with zip (by CI).
for app in greeter crypto_check tls_check; do
    if [ -f "$dir/$app.com" ]; then
        eval "check $app.com \"\$$app\""
    fi
done

# beam.com build, on this system: the examples of the repository.
if [ -d examples ]; then
    check beam.com 'wrote .*hashsum.b.com' \
        build examples/hashsum.erl -o "$dir/hashsum.b.com"
    [ -f "$dir/hashsum.b.com" ] && check hashsum.b.com "$hashsum" abc
    for app in greeter crypto_check tls_check calc; do
        check beam.com "wrote .*$app.b.com" \
            build "examples/$app" -o "$dir/$app.b.com"
        if [ -f "$dir/$app.b.com" ]; then
            eval "check $app.b.com \"\$$app\""
        fi
    done
fi

# One-file programs (beam_com_script) and the command line of beam.com.
if [ -d examples ]; then
    check beam.com 'wrote .*script_check.b.com' \
        build tests/programs/script_check.erl -o "$dir/script_check.b.com"
    if [ -f "$dir/script_check.b.com" ]; then
        check script_check.b.com 'argc 4@@arg a$@@arg b c$@@arg é$@@arg 日本$' \
            args a "b c" é 日本
        # Arguments are for the program, also when they look like flags.
        check script_check.b.com 'argc 4@@arg +S$@@arg 1$@@arg -extra$@@arg x$' \
            args +S 1 -extra x
        check script_check.b.com 'returning' return
        check_status 127 script_check.b.com 'raising@@exception error: {boom,42}' raise
        check_status 127 script_check.b.com 'exception throw: thrown_value' throw
        check_status 127 script_check.b.com 'exception exit: normal' exit
        check_status 3 script_check.b.com 'halting 3' halt 3
        # A crash report (Cosmopolitan's ShowCrashReports), with the
        # symbols of the zip; BEAM_COM_CRASH_REPORTS=0 turns it off.
        check_status 134 script_check.b.com 'aborting@@Uncaught SIGABRT@@halt_2' abort
        BEAM_COM_CRASH_REPORTS=0; export BEAM_COM_CRASH_REPORTS
        check_status 134 script_check.b.com 'aborting' abort
        if grep -q 'Uncaught' "$tmp"; then
            echo "FAIL: script_check.b.com printed a crash report with BEAM_COM_CRASH_REPORTS=0"
            failed="$failed
  script_check.b.com abort: a crash report with BEAM_COM_CRASH_REPORTS=0"
            fail=1
        fi
        unset BEAM_COM_CRASH_REPORTS
        check script_check.b.com '^line 100000$@@^last line$' big
        check script_check.b.com 'returned' spawn
        ERL_FLAGS='+S 1'
        export ERL_FLAGS
        check script_check.b.com 'schedulers 1$' info
        unset ERL_FLAGS
    fi
    check_status 1 beam.com 'usage: beam.com build INPUT' build
    check_status 1 beam.com 'none.erl: no such file' build none.erl
    check_status 1 beam.com 'unknown option -z' build x.erl -z
    check_status 1 beam.com 'option -o needs a value' build x.erl -o
    check_status 1 beam.com 'the application nosuch is not in beam.com' \
        build examples/hashsum.erl -a nosuch -o "$dir/never.com"
    check_status 1 beam.com 'aarch64-apple-darwin: Apple Silicon has no native form' \
        build examples/hashsum.erl --target aarch64-apple-darwin
    check_status 1 beam.com 'unknown target linux-x86_64' \
        build examples/hashsum.erl --target linux-x86_64

    # --target: a file for this system only, which the kernel starts
    # directly (no shell, no APE loader).
    case $os-$(uname -m) in
        linux-x86_64) native=x86_64-unknown-linux-gnu ;;
        linux-aarch64) native=aarch64-linux ;;
        freebsd-amd64) native=x86_64-unknown-freebsd ;;
        darwin-x86_64) native=x86_64-macos ;;
        *) native= ;;
    esac
    if [ -n "$native" ]; then
        check beam.com 'wrote .*hashsum.native' \
            build examples/hashsum.erl --target "$native" -o "$dir/hashsum.native"
        if [ -f "$dir/hashsum.native" ]; then
            saved_runner=$runner
            runner=
            check hashsum.native "$hashsum" abc
            runner=$saved_runner
        fi
    fi
fi

# The sandbox (beam.com build --allow-*). Linux applies it with seccomp
# and Landlock, OpenBSD only the paths (unveil), and the other systems
# ignore it.
if [ -d examples ]; then
    check_status 1 beam.com '--allow-net takes no hosts' \
        build tests/programs/sandbox_check.erl --allow-net=example.com -o "$dir/never.com"
    check_status 1 beam.com '--allow-env is not supported' \
        build tests/programs/sandbox_check.erl --allow-env -o "$dir/never.com"
    check_status 1 beam.com 'unknown option --allow-bogus' \
        build tests/programs/sandbox_check.erl --allow-bogus -o "$dir/never.com"
    check beam.com 'wrote .*sandbox_net.com' \
        build tests/programs/sandbox_check.erl -N -o "$dir/sandbox_net.com"
    check beam.com 'wrote .*sandbox_rw.com' \
        build tests/programs/sandbox_check.erl --allow-read=/etc \
        --allow-write="$dir/sandbox-w" -o "$dir/sandbox_rw.com"
    check beam.com 'wrote .*sandbox_run.com' \
        build tests/programs/sandbox_check.erl --allow-run=true -o "$dir/sandbox_run.com"
    check beam.com 'wrote .*sandbox_none.com' \
        build tests/programs/sandbox_check.erl -o "$dir/sandbox_none.com"
    rm -f "$dir/sandbox.tmp"
    net_extra= rw_extra=
    case $os in
        linux)
            net_extra='write '$dir/sandbox.tmp rw_extra=listen
            net='read: ok@@read: error eacces@@listen: ok@@write: error e[a-z]*@@done'
            rw='read: ok@@read: error eacces@@write: ok@@listen: error eperm@@done'
            runs='run: ok@@run: error@@done'
            env='read: ok@@read: error eacces@@done' ;;
        openbsd)
            net_extra='write '$dir/sandbox.tmp rw_extra=listen
            net='read: ok@@read: error e[a-z]*@@listen: ok@@write: error e[a-z]*@@done'
            rw='read: ok@@read: error e[a-z]*@@write: ok@@listen: ok@@done'
            runs=
            env='read: ok@@read: error e[a-z]*@@done' ;;
        *)
            net_extra='write '$dir/sandbox.tmp rw_extra=listen
            net='read: ok@@read: ok@@listen: ok@@write: ok@@done'
            rw='read: ok@@read: ok@@write: ok@@listen: ok@@done'
            runs='run: ok@@run: ok@@done'
            env='read: ok@@read: ok@@done' ;;
    esac
    # -N: the network, and the files that it needs (/etc/hosts), not
    # other files.
    check sandbox_net.com "$net" read /etc/hosts read "$dir/beam.com" listen $net_extra
    rm -f "$dir/sandbox.tmp"
    # A new file in a directory of --allow-write.
    rm -rf "$dir/sandbox-w"
    mkdir "$dir/sandbox-w"
    check sandbox_rw.com "$rw" \
        read /etc/hosts read "$dir/beam.com" write "$dir/sandbox-w/new.txt" $rw_extra
    rm -rf "$dir/sandbox-w"
    if [ -n "$runs" ]; then
        check sandbox_run.com "$runs" run true run sh
    else
        probe sandbox_run.com run true run sh
    fi
    # BEAM_COM_ALLOW: permissions for a program without them; a program
    # with permissions in its file ignores it.
    BEAM_COM_ALLOW='read=/etc;net'
    export BEAM_COM_ALLOW
    check sandbox_none.com "$env" read /etc/hosts read "$dir/beam.com"
    BEAM_COM_ALLOW=read
    check sandbox_net.com "$env" read /etc/hosts read "$dir/beam.com"
    unset BEAM_COM_ALLOW
fi

# Hex packages (from hex.pm, so this needs the network): hexweb needs
# cowboy (with cowlib and ranch) and jsx. The first build resolves the
# versions and writes rebar.lock; the second one uses rebar.lock and the
# cache, and does not write it again.
hexweb='hexweb: content-type application/json@@hexweb: hello BEAM.com; cowboy-[0-9.]* cowlib-[0-9.]* jsx-[0-9.]* ranch-[0-9.]*$'
if [ -d examples ]; then
    rm -f examples/hexweb/rebar.lock
    check beam.com 'wrote .*rebar.lock@@wrote .*hexweb.com@@applications: .*cowboy.*cowlib.*ranch.*jsx' \
        build examples/hexweb -o "$dir/hexweb.com"
    [ -f "$dir/hexweb.com" ] && check hexweb.com "$hexweb"
    if [ -f examples/hexweb/rebar.lock ]; then
        check beam.com 'wrote .*hexweb2.com' build examples/hexweb -o "$dir/hexweb2.com"
        if grep -q 'rebar.lock' "$tmp"; then
            echo "FAIL: the second build of hexweb wrote rebar.lock again"
            failed="$failed
  beam.com build examples/hexweb: wrote rebar.lock again"
            fail=1
        fi
        rm -f examples/hexweb/rebar.lock
    fi
fi

# Elixir: a one-file program, and a Mix project with a Hex package in
# Elixir (jason, from hex.pm) and config/config.exs.
greeter_ex='greeter_ex: Hello from config/config.exs (1)@@greeter_ex: Hello from config/config.exs (2)@@greeter_ex: json {.*"elixir":"1\.[0-9.]*".*}@@greeter_ex: decoded 1\.'
if [ -d examples ]; then
    check beam.com 'wrote .*elixir_check.com@@applications: .*elixir' \
        build tests/programs/elixir_check.ex -o "$dir/elixir_check.com"
    if [ -f "$dir/elixir_check.com" ]; then
        check elixir_check.com 'elixir: 1\.[0-9]*\.[0-9]* on OTP 29@@args: \["a", "b c", "日本"\]@@sum: 5050@@upcase: BEAM.COM' a "b c" 日本
        check_status 127 elixir_check.com '\*\* (RuntimeError) boom' raise
    fi
    rm -f examples/greeter_ex/mix.lock
    check beam.com 'wrote .*mix.lock@@wrote .*greeter_ex.com@@applications: .*jason' \
        build examples/greeter_ex -o "$dir/greeter_ex.com"
    [ -f "$dir/greeter_ex.com" ] && check greeter_ex.com "$greeter_ex"
    rm -f examples/greeter_ex/mix.lock
fi

# The tools: escript, and mix, iex, elixir and elixirc, as a first
# argument of beam.com or by the name of the file: mix.com, iex.com,
# elixir.com and elixirc.com are beam.com under other names (here hard
# links, as a copy), and mix, iex, elixir and escript are symbolic links.
# The Mix checks run in a new directory. BEAM_COM_TEST_OFFLINE=1 leaves
# out the checks that need hex.pm and builds.hex.pm.
cat > "$tmp.escript" <<'ESCRIPT'
#!/usr/bin/env escript
%%! +S 1 -escript main tools_escript
-module(tools_escript).
-export([main/1]).
main(Args) -> io:format("escript: ~p ~p~n", [Args, erlang:system_info(schedulers)]).
ESCRIPT
check beam.com 'escript: \["a","b c"\] 1$' escript "$tmp.escript" a "b c"
check beam.com '^55$' elixir -e 'IO.puts(Enum.sum(1..10))'
check beam.com '^Mix 1\.' mix --version
if [ -f "$dir/beam.com" ]; then
    here=$(pwd)
    work=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_mix.XXXXXX")
    dir_rel=$dir runner_rel=$runner
    dir=$(cd "$dir" && pwd)
    case $runner in */*) runner=$here/$runner ;; esac
    for t in mix iex elixir elixirc; do ln -f "$dir/beam.com" "$dir/$t.com"; done
    for t in mix iex elixir escript; do ln -sf beam.com "$dir/$t"; done
    cd "$work"
    check elixir.com '^55$@@^\["x", "y"\]$' -e 'IO.puts(Enum.sum(1..10)); IO.inspect(System.argv())' x y
    printf 'defmodule ToolsC do\n  def f, do: :ok\nend\n' > tools_c.ex
    check elixirc.com '' tools_c.ex -o out
    [ -f out/Elixir.ToolsC.beam ] || { echo "FAIL: elixirc wrote no beam file"; fail=1; failed="$failed
  elixirc.com: no out/Elixir.ToolsC.beam"; }
    check mix.com 'creating mix.exs' new hello
    cd hello
    check mix.com '2 passed' test
    check mix '' format --check-formatted
    check elixir '^world$' -S mix run -e 'IO.puts(Hello.hello())'
    # iex evaluates .iex.exs after the start of the shell (and of mix).
    printf 'IO.puts("iex: #{Hello.hello()}")\nSystem.halt()\n' > tools.iex.exs
    check iex.com '^iex: world$' --dot-iex tools.iex.exs -S mix
    # An escript from Mix: its "%%!" line names the main module.
    sed 's/deps: deps()/deps: deps(), escript: [main_module: Hello.CLI]/' mix.exs > mix.exs.new
    mv mix.exs.new mix.exs
    printf 'defmodule Hello.CLI do\n  def main(args), do: IO.puts("cli: #{inspect(args)}")\nend\n' > lib/cli.ex
    check mix 'Generated escript hello' escript.build
    check escript '^cli: \["p", "q"\]$' hello p q
    if [ "${BEAM_COM_TEST_OFFLINE:-0}" != 1 ]; then
        # Hex and rebar3 (for the Erlang packages), installed by Mix into
        # ~/.mix; Mix runs rebar3 with the escript in PATH. Where the kernel
        # cannot start an APE file and sh stops at its first NUL byte
        # (NetBSD), escript is a small script that starts the file with the
        # APE loader.
        if [ "$os" = netbsd ]; then
            rm -f "$dir/escript"
            printf '#!/bin/sh\nexec %s %s/beam.com escript "$@"\n' "$runner" "$dir" > "$dir/escript"
            chmod +x "$dir/escript"
        fi
        PATH=$dir:$PATH
        export PATH
        check mix '' local.hex --force
        check mix '' local.rebar --force
        sed 's/# {:dep_from_hexpm, "~> 0.3.0"},/{:jason, "~> 1.4"}, {:telemetry, "~> 1.3"},/' mix.exs > mix.exs.new
        mv mix.exs.new mix.exs
        check mix 'jason@@telemetry' deps.get
        check mix '^{"a":1}$@@^telemetry$' run -e 'IO.puts(Jason.encode!(%{a: 1})); IO.puts(:telemetry.module_info(:module))'
    fi
    cd "$here"
    rm -f "$dir/mix" "$dir/iex" "$dir/elixir" "$dir/escript" \
        "$dir/mix.com" "$dir/iex.com" "$dir/elixir.com" "$dir/elixirc.com"
    rm -rf "$work"
    dir=$dir_rel runner=$runner_rel
fi

# Phoenix from source, with the tools: a new app (mix phx.new, without
# Ecto), its deps from hex.pm and GitHub (heroicons is a git dep), and
# "iex.com -S mix phx.server" serves the start page. Linux only: it needs
# git, curl and the network (the esbuild and tailwind watchers download
# their programs).
if [ "$os" = linux ] && [ "${BEAM_COM_TEST_OFFLINE:-0}" != 1 ] && [ -f "$dir/beam.com" ] &&
   command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    here=$(pwd)
    work=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_phx.XXXXXX")
    dir_rel=$dir runner_rel=$runner limit_saved=$limit path_saved=$PATH
    dir=$(cd "$dir" && pwd)
    case $runner in */*) runner=$here/$runner ;; esac
    limit=600
    for t in mix iex; do ln -f "$dir/beam.com" "$dir/$t.com"; done
    for t in mix escript; do ln -sf beam.com "$dir/$t"; done
    PATH=$dir:$PATH
    export PATH
    cd "$work"
    check mix.com '' local.hex --force
    check mix.com 'phx_new' archive.install hex phx_new --force
    check mix.com 'creating hello/mix.exs' phx.new hello --no-ecto --no-install
    if [ -d hello ]; then
        cd hello
        check mix.com 'phoenix' deps.get
        check mix.com '' compile
        PORT=4123
        export PORT
        echo "==> iex.com -S mix phx.server"
        sleep 300 | $runner "$dir/iex.com" -S mix phx.server > "$tmp.phx" 2>&1 &
        phx=$!
        served=
        i=0
        while [ $i -lt 90 ]; do
            sleep 2
            i=$((i + 1))
            if curl -s http://127.0.0.1:$PORT/ 2>/dev/null | grep -q 'Phoenix Framework'; then
                served=yes
                break
            fi
        done
        unset PORT
        grep -v '^ *$' "$tmp.phx" | head -20
        if [ -n "$served" ]; then
            echo "PASS: iex.com -S mix phx.server (after $((i * 2)) s)"
        else
            echo "FAIL: iex.com -S mix phx.server did not serve the start page"
            fail=1
            failed="$failed
  iex.com -S mix phx.server: no start page on http://127.0.0.1:4123/"
        fi
        # Stop the VM (the program of the pipeline), then the sleep.
        pkill -f "$dir/iex.com" 2>/dev/null
        kill "$phx" 2>/dev/null
        pkill -f "^sleep 300$" 2>/dev/null
        wait "$phx" 2>/dev/null
    fi
    cd "$here"
    rm -f "$dir/mix" "$dir/escript" "$dir/mix.com" "$dir/iex.com"
    rm -rf "$work"
    dir=$dir_rel runner=$runner_rel limit=$limit_saved PATH=$path_saved
fi

# The file watcher (inotifywait of the file, for file_system and so
# phoenix_live_reload): the command line and the output of file_system.
# Linux has inotify; the other systems compare the files (moves are
# DELETE and CREATE there). Not on Windows.
if [ -f "$dir/beam.com" ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    mkdir "$wdir/sub"
    echo "==> beam.com inotifywait"
    $runner "$dir/beam.com" inotifywait -e modify -e close_write -e moved_to \
        -e moved_from -e create -e delete -e attrib --format '%w|%e|%f' \
        --quiet -m -r "$wdir" > "$tmp.watch" 2>&1 &
    watcher=$!
    sleep 2
    echo a > "$wdir/a.txt"
    mkdir "$wdir/new"
    sleep 1
    echo b > "$wdir/new/b.txt"
    rm "$wdir/a.txt"
    sleep 2
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    if grep -q "^$wdir/|CREATE|a.txt$" "$tmp.watch" &&
       grep -q "^$wdir/|CREATE,ISDIR|new$" "$tmp.watch" &&
       grep -q "^$wdir/new/|CREATE|b.txt$" "$tmp.watch" &&
       grep -q "^$wdir/|DELETE|a.txt$" "$tmp.watch"; then
        echo "PASS: beam.com inotifywait"
    else
        echo "FAIL: beam.com inotifywait"
        fail=1
        failed="$failed
  beam.com inotifywait: missing events"
    fi
    rm -rf "$wdir"
fi

# Distributed Erlang and remote shells (not on Windows). epmd is in the
# file, and starts only for -sname, -name or -remsh. examples/counter has
# -sname counter in its vm.args: "counter.com remote" is a shell in the
# running node, and so is "beam.com -remsh counter".
if [ -d examples ] && [ -f "$dir/beam.com" ]; then
    $runner "$dir/beam.com" epmd -kill > /dev/null 2>&1
    check beam.com 'Erlang/OTP' version
    check_status 1 beam.com 'Cannot connect to local epmd' epmd -names
    check beam.com 'wrote .*counter.com@@applications: kernel stdlib' \
        build examples/counter -o "$dir/counter.com"
    if [ -f "$dir/counter.com" ]; then
        $runner "$dir/counter.com" > "$tmp.counter" 2>&1 &
        counter=$!
        i=0
        while [ $i -lt 30 ] && ! $runner "$dir/beam.com" epmd -names 2>/dev/null | grep -q 'name counter'; do
            sleep 1
            i=$((i + 1))
        done
        check beam.com 'name counter at port' epmd -names
        # The end of the input ends the remote shell; halt() there would
        # stop the counter node.
        printf 'counter:incr(), counter:incr(), io:format("value ~p on ~p~n", [counter:value(), node()]).\n' > "$tmp.remsh"
        echo "==> counter.com remote"
        if $runner "$dir/counter.com" remote < "$tmp.remsh" 2>&1 | tee "$tmp.out" | grep -q '^.*value 2 on counter@'; then
            echo "PASS: counter.com remote"
        else
            cat "$tmp.out"
            echo "FAIL: counter.com remote"
            fail=1
            failed="$failed
  counter.com remote: no shell in the counter node"
        fi
        printf 'io:format("remsh ~p~n", [counter:value()]).\n' > "$tmp.remsh"
        echo "==> beam.com -remsh counter"
        if $runner "$dir/beam.com" -sname probe -setcookie beamcom -remsh counter < "$tmp.remsh" 2>&1 | tee "$tmp.out" | grep -q 'remsh 2'; then
            echo "PASS: beam.com -remsh counter"
        else
            cat "$tmp.out"
            echo "FAIL: beam.com -remsh counter"
            fail=1
            failed="$failed
  beam.com -sname probe -remsh counter: no shell in the counter node"
        fi
        kill "$counter" 2>/dev/null
        pkill -f "$dir/counter.com" 2>/dev/null
        wait "$counter" 2>/dev/null
    fi
    $runner "$dir/beam.com" epmd -kill > /dev/null 2>&1
fi

# An application with an entry (toolbox): the main module comes from
# escript_emu_args of rebar.config, a behaviour is compiled before the
# module that uses it, priv has an executable file (so it is copied to
# the cache at start), and the program starts itself again as erl.
toolbox_cache=$dir/toolbox-cache
if [ -d examples ]; then
    check beam.com 'wrote .*toolbox.com@@applications: beam_com_script kernel stdlib' \
        build examples/toolbox -o "$dir/toolbox.com"
    if [ -f "$dir/toolbox.com" ]; then
        rm -rf "$toolbox_cache"
        BEAM_COM_CACHE=$toolbox_cache; export BEAM_COM_CACHE
        check toolbox.com 'toolbox: Hello, Ana$' greet Ana
        check_status 2 toolbox.com 'toolbox: usage: ' nosuch
        check toolbox.com 'priv in /zip: false@@hello.sh says from-priv (a real file: .*toolbox-cache/priv/[0-9a-f]*/toolbox-1\.0\.0/priv/hello\.sh)' priv
        # The second start uses the files of the first.
        check toolbox.com 'hello.sh says from-priv' priv
        check toolbox.com '^peer: true [a-z]*$' peer
        unset BEAM_COM_CACHE
        # erl mode: a link named erl, or BEAM_COM_ERL=1.
        ln -sf toolbox.com "$dir/erl"
        check erl '^erl mode: true$' -noinput -eval \
            'io:format("erl mode: ~p~n", [code:which(toolbox_cli) =/= non_existing]), halt().'
        rm -f "$dir/erl"
        BEAM_COM_ERL=1; export BEAM_COM_ERL
        check toolbox.com '^schedulers: 1$' +S 1 -noinput -eval \
            'io:format("schedulers: ~p~n", [erlang:system_info(schedulers)]), halt().'
        unset BEAM_COM_ERL
    fi
    # --main names the module; it must export main/1.
    check beam.com 'wrote .*toolbox2.com' \
        build examples/toolbox --main toolbox_cli -o "$dir/toolbox2.com"
    [ -f "$dir/toolbox2.com" ] && check toolbox2.com 'toolbox: Hello, Bo$' greet Bo
    check_status 1 beam.com 'toolbox_english does not export main/1' \
        build examples/toolbox --main toolbox_english -o "$dir/never.com"
fi

# WebAssembly: wasm_check, and a WASI program in Go (made by CI).
wasm='wasm: add(40, 2) = 42@@wasm: trap: @@wasm: memory ok@@hello from wasi@@wasm: wasi exit code 7'
go='go: hello from wasip1, args \[one two\]@@go: BEAM_COM=1@@go: read back "written by go"@@exited with 0'
if [ -d examples ]; then
    check beam.com 'wrote .*wasm_check.b.com' \
        build examples/wasm_check.erl -o "$dir/wasm_check.b.com"
    if [ -f "$dir/wasm_check.b.com" ]; then
        check wasm_check.b.com "$wasm"
        if [ -f "$dir/hello_go.wasm" ]; then
            check wasm_check.b.com "$go" "$dir/hello_go.wasm" one two
        fi
    fi
fi

# The behavior tests of the wasm application.
if [ -d examples ]; then
    check beam.com 'wrote .*wasm_tests.b.com' \
        build tests/programs/wasm_tests.erl -o "$dir/wasm_tests.b.com"
    [ -f "$dir/wasm_tests.b.com" ] && check wasm_tests.b.com 'wasm_tests: all [0-9]* passed'
fi

if [ -d examples ]; then
    # W^X: the JIT maps its code two times (executable, and writable),
    # so no page is writable and executable. On Linux, +JMsingle (one
    # mapping) shows that the check sees RWX pages. macOS arm64 uses
    # one MAP_JIT mapping (RWX, with a write permission for each
    # thread). OpenBSD has no memory map for the program to read; its
    # kernel does not allow RWX pages at all.
    check beam.com 'wrote .*jit_maps.b.com' \
        build tests/programs/jit_maps.erl -o "$dir/jit_maps.b.com"
    if [ -f "$dir/jit_maps.b.com" ]; then
        case $os in
            linux)
                check jit_maps.b.com 'emulator: jit@@wx pages: 0$@@dual mapped: yes'
                ERL_FLAGS='+JMsingle true'
                export ERL_FLAGS
                check jit_maps.b.com 'wx pages: [1-9]@@dual mapped: no'
                unset ERL_FLAGS
                # With the sandbox, the launcher unveils the directory of
                # shm_open() (/dev/shm), so the JIT keeps its two views.
                check beam.com 'wrote .*jit_maps_unveil.b.com' \
                    build tests/programs/jit_maps.erl --allow-read=/proc \
                    -o "$dir/jit_maps_unveil.b.com"
                [ -f "$dir/jit_maps_unveil.b.com" ] &&
                    check jit_maps_unveil.b.com 'emulator: jit@@wx pages: 0$@@dual mapped: yes' ;;
            freebsd|netbsd)
                check jit_maps.b.com 'emulator: jit@@wx pages: 0$@@dual mapped: yes' ;;
            darwin)
                case $(uname -m) in
                    arm64) check jit_maps.b.com 'emulator: jit@@wx pages: [1-9]' ;;
                    *) check jit_maps.b.com 'emulator: jit@@wx pages: 0$' ;;
                esac ;;
            *)
                probe jit_maps.b.com ;;
        esac
    fi
fi

# The interpreter: beam-emu.com (beam.com has the JIT).
if [ -f "$dir/beam-emu.com" ]; then
    check beam-emu.com "Emulator    : emu@@OS type     : unix/$os" version
    if [ -d examples ]; then
        check beam-emu.com 'wrote .*hashsum.emu.com' \
            build examples/hashsum.erl -o "$dir/hashsum.emu.com"
        [ -f "$dir/hashsum.emu.com" ] && check hashsum.emu.com "$hashsum" abc
        check beam-emu.com 'wrote .*greeter.emu.com' \
            build examples/greeter -o "$dir/greeter.emu.com"
        [ -f "$dir/greeter.emu.com" ] && check greeter.emu.com "$greeter"
        check beam-emu.com 'wrote .*wasm_tests.emu.com' \
            build tests/programs/wasm_tests.erl -o "$dir/wasm_tests.emu.com"
        [ -f "$dir/wasm_tests.emu.com" ] && check wasm_tests.emu.com 'wasm_tests: all [0-9]* passed'
        check beam-emu.com 'wrote .*script_check.emu.com' \
            build tests/programs/script_check.erl -o "$dir/script_check.emu.com"
        if [ -f "$dir/script_check.emu.com" ]; then
            check script_check.emu.com 'argc 2@@arg b c$@@arg 日本$' args "b c" 日本
            check_status 127 script_check.emu.com 'exception error: {boom,42}' raise
            check_status 3 script_check.emu.com 'halting 3' halt 3
            check script_check.emu.com '^line 100000$@@^last line$' big
        fi
        check beam-emu.com 'wrote .*crypto_check.emu.com' \
            build examples/crypto_check -o "$dir/crypto_check.emu.com"
        [ -f "$dir/crypto_check.emu.com" ] && check crypto_check.emu.com "$crypto_check"
        # The sandbox with the interpreter (the sandbox checks above use
        # beam.com, the JIT, for which the launcher adds "prot_exec").
        check beam-emu.com 'wrote .*sandbox_net.emu.com' \
            build tests/programs/sandbox_check.erl -N -o "$dir/sandbox_net.emu.com"
        rm -f "$dir/sandbox.tmp"
        [ -f "$dir/sandbox_net.emu.com" ] && check sandbox_net.emu.com "$net" \
            read /etc/hosts read "$dir/beam.com" listen $net_extra
        rm -f "$dir/sandbox.tmp"
    fi
fi

# SQLite (in beam.com).
sqlite='sqlite: version 3@@sqlite: json \["alpha","beta","gamma"\]@@sqlite: 3 rows in '
if [ -d examples ]; then
    check beam.com 'wrote .*sqlite_check.b.com' \
        build examples/sqlite_check.erl -o "$dir/sqlite_check.b.com"
    if [ -f "$dir/sqlite_check.b.com" ]; then
        check sqlite_check.b.com "$sqlite:memory:"
        rm -f "$dir/test.db"
        check sqlite_check.b.com "${sqlite}$dir/test.db" "$dir/test.db"
    fi
    if [ -f "$dir/beam-emu.com" ]; then
        check beam-emu.com 'wrote .*sqlite_check.emu.com' \
            build examples/sqlite_check.erl -o "$dir/sqlite_check.emu.com"
        [ -f "$dir/sqlite_check.emu.com" ] && check sqlite_check.emu.com "$sqlite:memory:"
    fi
fi
rm -f "$tmp" "$tmp.diag"
# Processes that a test left behind (helper programs must stop with the
# emulator).
# No process of the tests may stay (for example erl_child_setup, see
# docs/UPSTREAM.md O12). A helper can need a moment to see the end of
# its program.
i=0
while [ -n "$(our_processes)" ] && [ $i -lt 5 ]; do
    sleep 1
    i=$((i + 1))
done
left=$(our_processes)
if [ -n "$left" ]; then
    fail=1
    failed="$failed
  processes still running after the tests"
    echo "==> Processes still running after the tests:"
    printf '%s\n' "$left"
    # The open files and the stack of the first one.
    first=$(printf '%s\n' "$left" | awk 'NR == 1 {print $1}')
    if command -v lsof >/dev/null 2>&1; then
        echo "--- lsof -p $first"
        lsof -p "$first" 2>&1 | head -40
    fi
    if command -v sample >/dev/null 2>&1; then
        echo "--- sample $first (macOS)"
        sample "$first" 1 2>&1 | head -80
    fi
fi
if [ $fail -ne 0 ]; then
    echo "==> Failed checks:$failed"
else
    echo "==> All checks passed"
fi
exit $fail
