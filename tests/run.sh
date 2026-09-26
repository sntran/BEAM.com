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
    [ "$runner" = sh ] || chmod +x "$runner"
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
            if ! grep -q "$p" "$tmp"; then
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

greeter='said hello 3 times'
crypto_check='sha256(abc) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello'
tls_check='ports: ok@@tls: local handshake ok@@tls: remote [^ ]* ok'
hashsum='^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$'

# The commands of the default beam.com. os:type() names this system.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
check beam.com 'usage: beam.com COMMAND@@build INPUT@@version'
check beam.com 'usage: beam.com COMMAND' help
check beam.com 'usage: beam.com build INPUT' help build
check beam.com "Erlang/OTP  : 29\.@@OS type     : unix/$os@@Emulator    : emu@@stdlib-@@esqlite-@@wasm-" version
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
    for app in greeter crypto_check tls_check; do
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

# The JIT probe: beam-jit.com is x86_64 only.
case $(uname -m) in
    x86_64|amd64) jit_cpu=1 ;;
    *) jit_cpu=0 ;;
esac
if [ -f "$dir/beam-jit.com" ] && [ $jit_cpu = 1 ]; then
    check beam-jit.com "Emulator    : jit@@OS type     : unix/$os" version
    if [ -d examples ]; then
        check beam-jit.com 'wrote .*hashsum.jit.com' \
            build examples/hashsum.erl -o "$dir/hashsum.jit.com"
        [ -f "$dir/hashsum.jit.com" ] && check hashsum.jit.com "$hashsum" abc
        check beam-jit.com 'wrote .*greeter.jit.com' \
            build examples/greeter -o "$dir/greeter.jit.com"
        [ -f "$dir/greeter.jit.com" ] && check greeter.jit.com "$greeter"
        check beam-jit.com 'wrote .*wasm_tests.jit.com' \
            build tests/programs/wasm_tests.erl -o "$dir/wasm_tests.jit.com"
        [ -f "$dir/wasm_tests.jit.com" ] && check wasm_tests.jit.com 'wasm_tests: all [0-9]* passed'
        check beam-jit.com 'wrote .*script_check.jit.com' \
            build tests/programs/script_check.erl -o "$dir/script_check.jit.com"
        if [ -f "$dir/script_check.jit.com" ]; then
            check script_check.jit.com 'argc 2@@arg b c$@@arg 日本$' args "b c" 日本
            check_status 127 script_check.jit.com 'exception error: {boom,42}' raise
            check_status 3 script_check.jit.com 'halting 3' halt 3
            check script_check.jit.com '^line 100000$@@^last line$' big
        fi
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
