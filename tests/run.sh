#!/bin/sh
# Run beam.com and the example programs, and check what they print.
# Usage: tests/run.sh DIR   (DIR holds beam.com and, if made, the example
#                            releases). Run it from the top of the
#                            repository to also test "beam.com INPUT -o OUTPUT".
#
# RUNNER is the command that starts an APE file (default: sh). On NetBSD
# and OpenBSD, sh stops at the NUL bytes of the APE header, so use the
# APE loader there: RUNNER=DIR/ape-x86_64.elf.
set -u
dir=${1:-.}
# tests/symtab.py, with an absolute path: some checks change the directory.
symtab_py=$(cd "$(dirname "$0")" && pwd)/symtab.py
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

# A process and all the processes under it, also the ones of other names
# (a port program such as sh) and the zombies.
tree() {
    ps -A -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
        { parent[$1] = $2; order[NR] = $1 }
        END {
            print root
            for (changed = 1; changed; ) {
                changed = 0
                for (i = 1; i <= NR; i++) {
                    p = order[i]
                    if (!(p in seen) && (parent[p] in mark || parent[p] == root)) {
                        seen[p] = 1; mark[p] = 1; changed = 1; print p
                    }
                }
            }
        }'
}

# The sample of macOS of a process: PID LINES. sample gives no names for
# the functions of an APE file, so tests/symtab.py adds them from the
# symbol table in the zip of the file (.symtab.arm64 or .symtab.amd64).
# Without python3 or a table, the sample has only the addresses.
sample_named() {
    com=$(lsof -p "$1" 2>/dev/null | awk '$4 == "txt" && $NF ~ /\.com$/ {print $NF; exit}')
    case $(uname -m) in arm64) table=.symtab.arm64 ;; *) table=.symtab.amd64 ;; esac
    if [ -n "$com" ] && command -v python3 >/dev/null 2>&1 &&
        unzip -p "$com" "$table" > "$tmp.symtab" 2>/dev/null && [ -s "$tmp.symtab" ]; then
        echo "(the names are from $table of $com)"
        sample "$1" 1 2>&1 | python3 "$symtab_py" "$tmp.symtab" | head -n "$2"
    else
        sample "$1" 1 2>&1 | head -n "$2"
    fi
    rm -f "$tmp.symtab"
}

# Called by the watchdog before it kills a program: the processes, and
# the stack traces where the system has a tool for it.
diagnose() {
    echo "--- processes"
    our_processes
    pids=$(tree "$1")
    echo "--- the process tree of $1"
    ps -A -o pid,ppid,pgid,stat,etime,command 2>/dev/null |
        awk -v list=" $(echo $pids) " 'NR == 1 || index(list, " " $1 " ")'
    for q in $pids; do
        if command -v sample >/dev/null 2>&1; then
            echo "--- sample $q (macOS)"
            sample_named "$q" 400
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

check_once() {
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
    # The watchdog checks once a second. When the program ends by itself,
    # the watchdog ends at its next check: a wait for it adds up to one
    # second to each check. A killed program (137) has its diagnostics:
    # the watchdog writes them before the kill.
    if [ $rc -eq 137 ]; then
        wait "$watchdog" 2>/dev/null
    fi
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
        pending="$pending
  $name $*: exited with $rc (expected $expect)"
        bad=1
    else
        # The patterns are separated by "@@". Each one must be found.
        ok=1
        rest=$pattern
        while [ -n "$rest" ]; do
            p=${rest%%@@*}
            case $rest in *@@*) rest=${rest#*@@} ;; *) rest= ;; esac
            if ! grep -q -e "$p" "$tmp"; then
                echo "FAIL: $name did not print \"$p\""
                pending="$pending
  $name $*: did not print \"$p\""
                ok=0
                bad=1
            fi
        done
        [ $ok -eq 1 ] && echo "PASS: $name"
    fi
}

# check NAME PATTERN ARGS...: run the program NAME of DIR with ARGS, and
# check its exit status and its output (check_once). With net=1 (net_check),
# the check uses the network (hex.pm, builds.hex.pm, a remote TLS host):
# a failure gets two more tries, after 10 s and after 30 s, and the log
# shows each try.
net=0
check() {
    try=1
    while :; do
        pending=
        bad=0
        check_once "$@"
        [ "$bad" = 1 ] || return 0
        if [ "$net" = 1 ] && [ "$try" -lt 3 ]; then
            wait=$((try * 20 - 10))
            echo "RETRY: $1 uses the network: try $((try + 1)) of 3 in $wait s"
            sleep "$wait"
            try=$((try + 1))
            continue
        fi
        fail=1
        failed="$failed$pending"
        return 0
    done
}

# net_check NAME PATTERN ARGS...: check, for a program that uses the network.
net_check() {
    net=1
    check "$@"
    net=0
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

# The versions of exqlite, bcrypt_elixir and argon2_elixir whose NIFs are
# in beam.com ("Linked NIFs" in "beam.com --version"), in exqlite_vsn,
# bcrypt_vsn and argon2_vsn (empty when a NIF is not linked).
linked_nifs() {
    linked=$($runner "$dir/beam.com" --version | sed -n 's/^  Linked NIFs : //p' | tr ' ' '\n')
    exqlite_vsn=$(echo "$linked" | sed -n 's/^exqlite-//p')
    bcrypt_vsn=$(echo "$linked" | sed -n 's/^bcrypt_elixir-//p')
    argon2_vsn=$(echo "$linked" | sed -n 's/^argon2_elixir-//p')
}

# After mix compiled exqlite, bcrypt_elixir and argon2_elixir (the output of check is in
# $tmp, and check has seen the exit status 0): no error of the compile or
# of make, and no NIF file (neither built nor downloaded). Not every
# "error" line: the app can log errors at run time (for example
# "database is locked" of Exqlite.Connection while ecto.migrate opens the
# pool on a new database, after which the connection tries again).
no_nif_build() {
    if grep -q -e 'Could not compile' -e '== Compilation error' -e ': make: ' \
            -e 'Compilation failed' "$tmp" ||
       [ -e _build/dev/lib/exqlite/priv/sqlite3_nif.so ] ||
       [ -e _build/dev/lib/bcrypt_elixir/priv/bcrypt_nif.so ] ||
       [ -e _build/dev/lib/argon2_elixir/priv/argon2_nif.so ]; then
        echo "FAIL: mix built or downloaded a NIF of exqlite, bcrypt_elixir or argon2_elixir"
        fail=1
        failed="$failed
  mix: an error, or a NIF file of exqlite, bcrypt_elixir or argon2_elixir in _build"
    else
        echo "PASS: no NIF built for exqlite, bcrypt_elixir and argon2_elixir"
    fi
}

greeter='said hello 3 times'
crypto_check='sha256(abc) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello'
tls_check='ports: ok@@tls: local handshake ok@@tls: remote [^ ]* ok'
hashsum='^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$'
calc='calc: 1 + 2 \* (3 - 1) - 8 / 4 = 3$@@calc: asn1 ber 300980044245414d810103$@@calc: asn1 decoded BEAM 3$'

# The commands of the default beam.com. os:type() names this system.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
# With no input, beam.com runs the project in the current directory. The
# top of the repository is a Mix project, so this check runs in an empty
# directory.
top=$(pwd) top_dir=$dir top_runner=$runner
dir=$(cd "$dir" && pwd)
case $runner in /*) ;; */*) runner=$top/$runner ;; esac
empty=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_empty.XXXXXX")
cd "$empty"
check beam.com 'run INPUT (default: the project in this directory)@@make an executable of INPUT@@--help | --version'
cd "$top"
dir=$top_dir runner=$top_runner
rmdir "$empty"
check beam.com 'run INPUT (default: the project in this directory)' --help
check beam.com "Erlang/OTP  : 29\.@@OS type     : unix/$os@@Emulator    : jit@@stdlib-@@esqlite-@@wasm-" --version
# The architecture is the CPU and the system where the file runs (O28 of
# docs/UPSTREAM.md), not the one text of configure.
case $(uname -m) in arm64|aarch64) cpu=aarch64 ;; amd64|x86_64) cpu=x86_64 ;; *) cpu=$(uname -m) ;; esac
check beam.com "^arch: $cpu-[a-z]*-$os" -noshell -eval 'io:format("arch: ~ts~n", [erlang:system_info(system_architecture)]), halt().'
check_status 1 beam.com 'nosuch: not a .erl, .ex or .exs file, or a directory' nosuch
check_status 1 beam.com 'there is no command build: use "beam.com INPUT -o OUTPUT"' build
check_status 1 beam.com 'the arguments of the program come after "--"' x.erl y
# The --strace flag of the Cosmopolitan runtime (README, "Debugging").
check beam.com 'SYS @@Erlang/OTP  : ' --strace --version
# A port program gets only the descriptors 0, 1 and 2 of the emulator, as
# with the BEAM. On macOS, the closefrom() of erl_child_setup closed
# nothing (C37 of docs/UPSTREAM.md). The list also has the descriptors of
# ls: on Linux, 3 for /dev/fd. On macOS, fts_open() opens "." as 3, and
# then /dev/fd as 4.
fds_eval='P = open_port({spawn_executable, "/bin/ls"}, [binary, exit_status, {args, ["/dev/fd"]}]),
    F = fun F(A) -> receive {P, {data, D}} -> F(<<A/binary, D/binary>>); {P, {exit_status, _}} -> A end end,
    io:format("fds: ~s~n", [lists:join(" ", string:lexemes(F(<<>>), "\n"))]),
    halt().'
case $os in
linux) check beam.com '^fds: 0 1 2 3$' -noshell -eval "$fds_eval" ;;
darwin) check beam.com '^fds: 0 1 2 3 4$' -noshell -eval "$fds_eval" ;;
esac
# 200 port programs, one after the other: erl_child_setup forks for each
# one (C36 of docs/UPSTREAM.md).
ports_eval='N = length([ok || _ <- lists:seq(1, 200),
        begin P = open_port({spawn_executable, "/bin/sh"}, [exit_status, {args, ["-c", "exit 0"]}]),
              receive {P, {exit_status, 0}} -> true end end]),
    io:format("ports: ~p~n", [N]),
    halt().'
check beam.com '^ports: 200$' -noshell -eval "$ports_eval"
# The thread stacks on Linux are plain maps, with no MAP_GROWSDOWN (C45
# of docs/UPSTREAM.md): Rosetta does not handle MAP_GROWSDOWN as Linux
# does. --strace of Cosmopolitan shows each mmap() of the start.
if [ "$os" = linux ]; then
    echo "==> beam.com --strace: the thread stacks"
    $runner "$dir/beam.com" --strace -noshell -eval 'halt().' > "$tmp" 2>&1
    growsdown=$(grep -c MAP_GROWSDOWN "$tmp")
    threads=$(grep -c pthread_create "$tmp")
    if [ "$growsdown" != 0 ] || [ "$threads" = 0 ]; then
        echo "FAIL: beam.com: $growsdown maps with MAP_GROWSDOWN, $threads threads"
        fail=1
        failed="$failed
  beam.com --strace: $growsdown maps with MAP_GROWSDOWN, $threads threads"
    fi
fi
# The ssh application of the zip: a daemon on a free port of 127.0.0.1,
# with a new host key, and a client that logs in to it with a password.
rm -rf "$dir/ssh_check"
ssh_eval='{ok, _} = application:ensure_all_started(ssh),
    D = "'"$dir/ssh_check"'",
    ok = filelib:ensure_path(D),
    K = public_key:generate_key({namedCurve, secp256r1}),
    ok = file:write_file(filename:join(D, "ssh_host_ecdsa_key"),
                         public_key:pem_encode([public_key:pem_entry_encode(list_to_atom("ECPrivateKey"), K)])),
    {ok, S} = ssh:daemon({127,0,0,1}, 0, [{system_dir, D}, {user_passwords, [{"u", "p"}]}, {auth_methods, "password"}]),
    {port, P} = lists:keyfind(port, 1, case ssh:daemon_info(S, [port]) of {ok, I} -> I; I -> I end),
    {ok, C} = ssh:connect({127,0,0,1}, P, [{user, "u"}, {password, "p"}, {user_dir, D}, {silently_accept_hosts, true},
                                          {user_interaction, false}, {save_accepted_host, false}]),
    ok = ssh:close(C),
    ok = ssh:stop_daemon(S),
    io:format("ssh: ok~n"),
    halt().'
check beam.com '^ssh: ok$' -noshell -eval "$ssh_eval"
rm -rf "$dir/ssh_check"

# SSL_CERT_FILE: public_key:cacerts_get/0 reads the certificates of that
# file in place of the certificates of the OS, as OpenSSL does (a proxy
# that terminates TLS gives its CA in it). The file holds the first
# certificate of the OS.
os_ca=
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/cert.pem; do
    [ -f "$f" ] && os_ca=$f && break
done
if [ -n "$os_ca" ]; then
    awk '/BEGIN CERTIFICATE/ {p = 1} p {print} /END CERTIFICATE/ {exit}' "$os_ca" > "$dir/ca-one.pem"
    cacerts_eval='io:format("cacerts: ~p~n", [length(public_key:cacerts_get())]), halt().'
    SSL_CERT_FILE=$dir/ca-one.pem
    export SSL_CERT_FILE
    check beam.com '^cacerts: 1$' -noshell -eval "$cacerts_eval"
    # The user's own -public_key wins.
    check beam.com '^cacerts: [0-9][0-9]' -public_key cacerts_path "\"$os_ca\"" \
        -noshell -eval "$cacerts_eval"
    # A file that does not exist, and a directory: the certificates of
    # the OS.
    SSL_CERT_FILE=$dir/ca-none.pem
    check beam.com '^cacerts: [0-9][0-9]' -noshell -eval "$cacerts_eval"
    SSL_CERT_FILE=$dir
    check beam.com '^cacerts: [0-9][0-9]' -noshell -eval "$cacerts_eval"
    unset SSL_CERT_FILE
fi

# Linux: when the APE loader runs beam.com (sh starts it), the helper
# programs start with that loader, and the kernel never gets the APE file
# (on WSL, the binfmt_misc entry WSLInterop gives it to Windows). The
# shell of os:cmd/1 is a child of erl_child_setup: its parent has the
# /proc/PID/exe of the emulator (the loader). A program that starts its
# own file (erl mode) uses the loader too. A native file starts its own
# file with the kernel.
loader_eval='{ok, [[E]]} = init:get_argument(beam_com_exe),
    {ok, Self} = file:read_link("/proc/self/exe"),
    Cs = string:trim(os:cmd("readlink /proc/$PPID/exe")),
    io:format("child_setup: ~s~n", [if Self =:= E -> native; Cs =:= Self -> loader; true -> Cs end]),
    {ok, _} = inet:gethostbyname("localhost"),
    P = open_port({spawn_executable, E}, [{env, [{"BEAM_COM_ERL", "1"}]}, exit_status,
        {args, ["-noshell", "-eval", "io:format(\"erl mode ok~n\"), halt()."]}]),
    receive {P, {data, D}} -> io:format("~s", [D]) end,
    halt().'
if [ "$os" = linux ] && [ "$runner" = sh ] && [ -f "$dir/beam.com" ]; then
    check beam.com 'child_setup: loader@@erl mode ok@@starting .*/beam.com with the APE loader' \
        -noshell -eval "$loader_eval"
    cp "$dir/beam.com" "$dir/beam-native.com"
    sh "$dir/beam-native.com" --assimilate
    runner=
    # The shell script of an APE file makes a native file (ELF) only on
    # x86_64; on aarch64, --assimilate leaves the APE file (the APE loader
    # runs it there). The checks of a native file need a native file.
    magic=$(dd if="$dir/beam-native.com" bs=4 count=1 2>/dev/null | od -An -c | tr -d ' ')
    if [ "$magic" != 177ELF ]; then
        echo "SKIP: beam-native.com (--assimilate made no native file on $(uname -m))"
    else
    check beam-native.com 'child_setup: native@@erl mode ok' -noshell -eval "$loader_eval"
    if grep -q 'with the APE loader' "$tmp"; then
        echo "FAIL: beam-native.com started a file with the APE loader"
        failed="$failed
  beam-native.com: started a file with the APE loader"
        fail=1
    fi
    # A build from a native file: an error without --target (the program
    # would run only on this system), a native file with the --target of
    # this system.
    if [ -d examples ]; then
        case $(uname -m) in aarch64) cpu=aarch64 ;; *) cpu=x86_64 ;; esac
        check_status 1 beam-native.com "beam-native.com: this is a native file (ELF, $cpu), not an APE file" \
            examples/hashsum.erl -o "$dir/never.com"
        [ -f "$dir/never.com" ] && { echo "FAIL: beam-native.com wrote never.com"; fail=1; failed="$failed
  beam-native.com -o: wrote a file"; }
        check beam-native.com 'wrote .*hashsum.native2' \
            examples/hashsum.erl --target "$cpu-linux" -o "$dir/hashsum.native2"
        [ -f "$dir/hashsum.native2" ] && check hashsum.native2 "$hashsum" abc
        rm -f "$dir/never.com" "$dir/hashsum.native2"
    fi
    fi
    runner=sh

    # WSL on Linux: since Linux 6.7, a user namespace can have its own
    # binfmt_misc. There, an entry as WSLInterop sends each "MZ" file to
    # a fake Windows, which fails as on WSL. beam.com, its helpers (also
    # epmd), erl mode and the file watcher of the tools must work there.
    printf '#!/bin/sh\necho "WSLInterop got $1" >&2\nexit 77\n' > "$tmp.win"
    cat > "$tmp.wsl" <<WSL
#!/bin/sh
exec unshare -U -r -m sh -c 'mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc &&
    echo ":WSLInterop:M::MZ::$tmp.win:" > /proc/sys/fs/binfmt_misc/register &&
    exec sh "\$@"' sh "\$@"
WSL
    chmod +x "$tmp.win" "$tmp.wsl"
    if "$tmp.wsl" -c true 2>/dev/null; then
        runner=$tmp.wsl
        pre=$failed
        check beam.com 'child_setup: loader@@erl mode ok@@wsl_names {ok,\[{"wsl_check"' -sname wsl_check \
            -noshell -eval "io:format(\"wsl_names ~p~n\", [net_adm:names()]), $loader_eval"
        # The facts of a failure: the user, the program file, and the
        # calls that find the program file and its zip. The next check
        # removes $tmp.diag.
        if [ "$failed" != "$pre" ]; then
            echo "--- the fake WSL: the user, the uid map and the program file"
            $runner -c 'id; cat /proc/self/uid_map; ls -la "$1"' sh "$dir/beam.com" 2>&1
            if command -v strace > /dev/null 2>&1; then
                echo "--- strace of beam.com -sname in the fake WSL"
                $runner -c 'exec strace -f -e trace=execve,openat,readlink,readlinkat -o "$1" sh "$2" -sname wsl_strace -noshell -eval "halt()."' \
                    sh "$tmp.diag" "$dir/beam.com" > /dev/null 2>&1
                grep -v -E 'ENOENT|/lib/|/etc/ld' "$tmp.diag" | head -n 80
            fi
        fi
        $runner "$dir/beam.com" epmd -kill > /dev/null 2>&1
        check beam.com '^usage: inotifywait ' elixir -e '{out, 1} = System.cmd("sh", ["-c", System.fetch_env!("FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE")], stderr_to_stdout: true); IO.write(out)'
        runner=sh
        if grep -q 'WSLInterop got' "$tmp"; then
            echo "FAIL: the kernel got an APE file (WSLInterop)"
            failed="$failed
  WSLInterop: the kernel got an APE file"
            fail=1
        fi
    else
        echo "SKIP: WSLInterop (no user namespace with its own binfmt_misc)"
    fi
    rm -f "$tmp.win" "$tmp.wsl" "$dir/beam-native.com"
fi

# Releases made with rebar3 and added with zip (by CI).
# tls_check connects to a remote host: net_check.
for app in greeter crypto_check tls_check; do
    c=check
    [ "$app" = tls_check ] && c=net_check
    if [ -f "$dir/$app.com" ]; then
        eval "$c $app.com \"\$$app\""
    fi
done

# beam.com INPUT -o OUTPUT, on this system: an example and the check
# programs of the repository.
if [ -d examples ]; then
    check beam.com 'wrote .*hashsum.b.com' \
        examples/hashsum.erl -o "$dir/hashsum.b.com"
    [ -f "$dir/hashsum.b.com" ] && check hashsum.b.com "$hashsum" abc
    for src in examples/greeter tests/programs/crypto_check tests/programs/tls_check \
               tests/programs/calc; do
        app=$(basename "$src")
        check beam.com "wrote .*$app.b.com" \
            "$src" -o "$dir/$app.b.com"
        c=check
        [ "$app" = tls_check ] && c=net_check
        if [ -f "$dir/$app.b.com" ]; then
            eval "$c $app.b.com \"\$$app\""
        fi
    done
fi

# One-file programs (beam_com_script) and the command line of beam.com.
if [ -d examples ]; then
    check beam.com 'wrote .*script_check.b.com' \
        tests/programs/script_check.erl -o "$dir/script_check.b.com"
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
        # A slow reader of the standard output: it reads only after 3 s,
        # and it must get each line.
        slow=$($runner "$dir/script_check.b.com" big 1000000 2>/dev/null | (sleep 3; wc -l))
        if [ "$slow" -eq 1000001 ] 2>/dev/null; then
            echo "PASS: script_check.b.com big 1000000 with a slow reader"
        else
            echo "FAIL: script_check.b.com big 1000000 with a slow reader: $slow lines"
            fail=1
            failed="$failed
  script_check.b.com big 1000000 with a slow reader: $slow lines (expected 1000001)"
        fi
        check script_check.b.com 'returned' spawn
        ERL_FLAGS='+S 1'
        export ERL_FLAGS
        check script_check.b.com 'schedulers 1$' info
        unset ERL_FLAGS
    fi
    # The peer module of OTP: the program starts its own file in erl mode,
    # with the standard I/O and then a TCP connection as the channel.
    check beam.com 'wrote .*peer_check.b.com' \
        tests/programs/peer_check.erl -o "$dir/peer_check.b.com"
    if [ -f "$dir/peer_check.b.com" ]; then
        peer_line='release [0-9][0-9]*, sum 6, own code true, error boom, bytes 1000000, sent 1000000'
        check peer_check.b.com "^peer standard_io: $peer_line\$@@^peer tcp: $peer_line\$@@^exit status 3\$@@^cmd hello\$@@^slow reader 200000\$@@^halt reader 4097\$@@^closed listen socket refused\$@@^find executable true\$@@^script ok\$@@^nouse_stdio fd ping\$"
    fi
    # The blue-green spike (examples/bluegreen): an upgrade under load, and
    # three upgrades that the server refuses. Linux has a result; the other
    # systems have other rules for SO_REUSEPORT, so there it is a probe,
    # with 5000 requests, so that the load still runs at the switch.
    # check.sh is a shell script: sh starts it, and it starts each APE file
    # with RUNNER (the APE loader on NetBSD and OpenBSD).
    if [ -f "$dir/beam.com" ]; then
        cp -R examples/bluegreen "$dir/"
        bluegreen='^upgrade to version 2$@@^load: [0-9]* ok, 0 failed, counts in order true, versions \[1,2\]'
        bluegreen="$bluegreen@@{unknown_state,@@{cannot_start,eacces}@@{cannot_start,enoent}"
        bluegreen="$bluegreen@@^load: 3 ok, 0 failed, counts in order true, versions \[2\]"
        saved_runner=$runner
        RUNNER=$runner
        export RUNNER
        runner=sh
        case $os in
            linux) check bluegreen/check.sh "$bluegreen" "$dir/beam.com" ;;
            *) probe bluegreen/check.sh "$dir/beam.com" 18451 5000 ;;
        esac
        # New code in a running program (examples/reload): zip puts new
        # modules into its file, and the program loads them. It needs zip
        # (Info-ZIP). A probe on the systems other than Linux.
        if command -v zip > /dev/null; then
            cp -R examples/reload "$dir/"
            reload='^hello: v1 2$@@^build: .*last => {ok,\[reload_text\]}@@^status: .*last => {ok,\[reload_loop,reload_text\]}@@^hello: v2 3$'
            reload="$reload@@^loop: loop 1\$@@last => {waiting,\[reload_loop\]}@@^status: .*last => {ok,\[reload_loop\]}"
            reload="$reload@@^after move: loop 2\$@@^state: #{count => 3,extra => to_map}\$@@^hello: v2 4\$"
            reload="$reload@@^file: hello 2 changes 1\$@@^outside: v2 5\$@@^off: no reload\$"
            case $os in
                linux) check reload/check.sh "$reload" "$dir/beam.com" ;;
                *) probe reload/check.sh "$dir/beam.com" ;;
            esac
        fi
        runner=$saved_runner
    fi
    # A run: the executable in the cache, with the arguments after "--"
    # and the exit status of the program.
    check beam.com "$hashsum" examples/hashsum.erl -- abc
    check_status 2 beam.com '^usage: hashsum TEXT' examples/hashsum.erl
    check_status 1 beam.com 'none.erl: no such file' none.erl
    check_status 1 beam.com 'unknown option -z' x.erl -z
    check_status 1 beam.com 'option -o needs a value' x.erl -o
    check_status 1 beam.com 'the application nosuch is not in beam.com' \
        examples/hashsum.erl -a nosuch -o "$dir/never.com"
    check_status 1 beam.com 'aarch64-apple-darwin: Apple Silicon has no native form' \
        examples/hashsum.erl --target aarch64-apple-darwin
    check_status 1 beam.com 'unknown target linux-x86_64' \
        examples/hashsum.erl --target linux-x86_64

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
            examples/hashsum.erl --target "$native" -o "$dir/hashsum.native"
        if [ -f "$dir/hashsum.native" ]; then
            saved_runner=$runner
            runner=
            check hashsum.native "$hashsum" abc
            runner=$saved_runner
        fi
    fi
fi

# The sandbox (beam.com INPUT --allow-* -o OUTPUT). Linux applies it with seccomp
# and Landlock, OpenBSD only the paths (unveil), and the other systems
# ignore it.
if [ -d examples ]; then
    check_status 1 beam.com '--allow-net: a bad domain' \
        tests/programs/sandbox_check.erl '--allow-net=*.com' -o "$dir/never.com"
    check_status 1 beam.com '--allow-env is not supported' \
        tests/programs/sandbox_check.erl --allow-env -o "$dir/never.com"
    check_status 1 beam.com 'unknown option --allow-bogus' \
        tests/programs/sandbox_check.erl --allow-bogus -o "$dir/never.com"
    check beam.com 'wrote .*sandbox_net.com' \
        tests/programs/sandbox_check.erl -N -o "$dir/sandbox_net.com"
    check beam.com 'wrote .*sandbox_rw.com' \
        tests/programs/sandbox_check.erl --allow-read=/etc \
        --allow-write="$dir/sandbox-w" -o "$dir/sandbox_rw.com"
    check beam.com 'wrote .*sandbox_run.com' \
        tests/programs/sandbox_check.erl --allow-run=true -o "$dir/sandbox_run.com"
    check beam.com 'wrote .*sandbox_none.com' \
        tests/programs/sandbox_check.erl -o "$dir/sandbox_none.com"
    rm -f "$dir/sandbox.tmp"
    # A kernel of Linux with no Landlock (issue 171): beam.com prints a
    # warning at the start of a sandbox, and checks the paths and the
    # sockets in the calls of the C library, as on Windows. A refused
    # socket then gives EACCES (the wrap), not EPERM (pledge).
    landlock=1 sock=eperm
    if [ "$os" = linux ]; then
        BEAM_COM_ALLOW=read=/etc BEAM_COM_VERBOSE=1 $runner "$dir/sandbox_none.com" > "$tmp.landlock" 2>&1
        if grep -q 'the kernel has no Landlock' "$tmp.landlock"; then
            landlock=0 sock=eacces
            echo "NOTE: this kernel has no Landlock"
        fi
        rm -f "$tmp.landlock"
    fi
    net_extra= rw_extra=
    case $os-$(uname -m) in
        linux-*)
            net_extra="write $dir/sandbox.tmp sockopts rawopt" rw_extra=listen
            net='read: ok@@read: error eacces@@listen: ok@@write: error e[a-z]*@@sockopts: ok@@rawopt: refused@@done'
            rw="read: ok@@read: error eacces@@write: ok@@listen: error $sock@@done"
            runs='run true: ok@@run sh: error@@done'
            env='read: ok@@read: error eacces@@done' ;;
        openbsd-*)
            net_extra="write $dir/sandbox.tmp sockopts" rw_extra=listen
            net='read: ok@@read: error e[a-z]*@@listen: ok@@write: error e[a-z]*@@sockopts: ok@@done'
            rw='read: ok@@read: error e[a-z]*@@write: ok@@listen: ok@@done'
            runs=
            env='read: ok@@read: error e[a-z]*@@done' ;;
        # Seatbelt (c_src/cosmo/beam_com_seatbelt.c) refuses with EPERM.
        darwin-arm64)
            net_extra="write $dir/sandbox.tmp sockopts" rw_extra=listen
            net='read: ok@@read: error eperm@@listen: ok@@write: error eperm@@sockopts: ok@@done'
            rw='read: ok@@read: error eperm@@write: ok@@listen: error e[a-z]*@@done'
            runs='run true: ok@@run sh: error@@done'
            env='read: ok@@read: error eperm@@done' ;;
        *)
            net_extra="write $dir/sandbox.tmp sockopts" rw_extra=listen
            net='read: ok@@read: ok@@listen: ok@@write: ok@@sockopts: ok@@done'
            rw='read: ok@@read: ok@@write: ok@@listen: ok@@done'
            runs='run true: ok@@run sh: ok@@done'
            env='read: ok@@read: ok@@done' ;;
    esac
    # -N: the network, and the files that it needs (/etc/hosts), not
    # other files. The options of a TCP socket that inet sets and reads
    # (issue 157), but on Linux not each option (rawopt).
    check sandbox_net.com "$net" read /etc/hosts read "$dir/beam.com" listen $net_extra
    rm -f "$dir/sandbox.tmp"
    # A new file in a directory of --allow-write.
    rm -rf "$dir/sandbox-w"
    mkdir "$dir/sandbox-w"
    check sandbox_rw.com "$rw" \
        read /etc/hosts read "$dir/beam.com" write "$dir/sandbox-w/new.txt" $rw_extra
    rm -rf "$dir/sandbox-w"
    pre=$failed
    if [ -n "$runs" ]; then
        check sandbox_run.com "$runs" run true run sh
    else
        probe sandbox_run.com run true run sh
    fi
    # The refusals of Seatbelt (c_src/cosmo/beam_com_seatbelt.c) go to the
    # log of macOS, not to the program. For a failed check, print the log
    # of the processes of the APE loader and the newest crash report (its
    # name starts with ".ape", so ls needs -A). BEAM_COM_SEATBELT_OMIT
    # leaves parts of the profile out, to find the part that stops it.
    if [ "$failed" != "$pre" ] && [ "$os-$(uname -m)" = darwin-arm64 ] &&
       command -v log >/dev/null; then
        echo "--- the log of macOS for the processes of the APE loader, last 5 minutes"
        log show --style compact --last 5m --predicate 'eventMessage CONTAINS[c] "ape-1.10"' 2>&1 |
            tail -80
        for f in $(ls -At "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i ape | head -1); do
            echo "--- $f"
            head -c 16000 "$HOME/Library/Logs/DiagnosticReports/$f"
            echo
        done
    fi
    # The claims of docs/SANDBOX.md (tests/sandbox_claims.txt): each line
    # runs sandbox_none.com with BEAM_COM_ALLOW and its action, and checks
    # the result of this system. The directories of $IN and $OUT are new
    # for each line. The table is on the file descriptor 3, so that the
    # programs do not read it.
    # On Linux, a kernel with no Landlock (issue 171) has its own column
    # ($landlock, see above).
    case $os-$(uname -m)-$landlock in
        linux-*-1) col=4 ;;
        linux-*-0) col=5 ;;
        darwin-arm64-*) col=6 ;;
        openbsd-*) col=8 ;;
        *) col=9 ;;
    esac
    claims=$dir/claims
    self=$dir/sandbox_none.com
    tab=$(printf '\t')
    awk -F ' [|] ' -v c="$col" '$0 !~ /^#/ && NF > 0 {
            if (NF != 9) { print "BAD\t" $0; next }
            print $1 "\t" $2 "\t" $3 "\t" $c
        }' "$top/tests/sandbox_claims.txt" > "$tmp.claims"
    while IFS=$tab read -r claim allow action want <&3; do
        if [ "$claim" = BAD ]; then
            echo "FAIL: tests/sandbox_claims.txt: a line without 9 fields: $allow"
            fail=1
            failed="$failed
  tests/sandbox_claims.txt: a line without 9 fields"
            continue
        fi
        echo "--- claim: $claim"
        if [ "$want" = - ]; then
            echo "SKIP: not on this system"
            continue
        fi
        rm -rf "$claims"
        mkdir -p "$claims/in/sub" "$claims/in/d" "$claims/out/d"
        echo a > "$claims/in/a.txt"
        echo b > "$claims/in/sub/b.txt"
        echo a > "$claims/out/a.txt"
        # $SOCK: a Unix socket that listens, so that a refused connection
        # gets the error of the sandbox, not ENOENT.
        sock_pid=
        case $action in
            *'$SOCK'*)
                if ! command -v python3 >/dev/null; then
                    echo "SKIP: no python3 for the socket of \$SOCK"
                    continue
                fi
                python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(8)
time.sleep(120)' "$claims/in/srv.sock" &
                sock_pid=$!
                i=0
                while [ ! -S "$claims/in/srv.sock" ] && [ $i -lt 50 ]; do
                    sleep 0.1
                    i=$((i + 1))
                done ;;
        esac
        allow=$(printf '%s' "$allow" | sed "s#\$IN#$claims/in#g; s#\$OUT#$claims/out#g")
        action=$(printf '%s' "$action" |
            sed "s#\$IN#$claims/in#g; s#\$OUT#$claims/out#g; s#\$SELF#$self#g; s#\$SOCK#$claims/in/srv.sock#g")
        # shellcheck disable=SC2086 # The words of the action.
        set -- $action
        name=$1
        [ "$1" = run ] && name="run $2"
        BEAM_COM_ALLOW=$allow
        export BEAM_COM_ALLOW
        check sandbox_none.com "^$name: $want\$" "$@"
        unset BEAM_COM_ALLOW
        if [ -n "$sock_pid" ]; then
            kill "$sock_pid" 2>/dev/null
            wait "$sock_pid" 2>/dev/null
        fi
    done 3< "$tmp.claims"
    rm -rf "$claims" "$tmp.claims"
    # BEAM_COM_ALLOW: permissions for a program without them; a program
    # with permissions in its file ignores it.
    BEAM_COM_ALLOW='read=/etc;net'
    export BEAM_COM_ALLOW
    check sandbox_none.com "$env" read /etc/hosts read "$dir/beam.com"
    BEAM_COM_ALLOW=read
    check sandbox_net.com "$env" read /etc/hosts read "$dir/beam.com"
    unset BEAM_COM_ALLOW
    # chown() to the owner that a file already has (C28 of
    # docs/UPSTREAM.md): outside the sandbox, the result of the system.
    # Linux clears the setuid and setgid bits at each chown().
    rm -rf "$dir/sandbox-w"
    mkdir "$dir/sandbox-w"
    if [ "$os" = linux ]; then
        check sandbox_none.com 'write: ok@@setid: owner 755, times 755@@done' \
            write "$dir/sandbox-w/g" setid "$dir/sandbox-w/g"
    else
        check sandbox_none.com 'write: ok@@owner: ok@@touch: ok@@done' \
            write "$dir/sandbox-w/g" owner "$dir/sandbox-w/g" touch "$dir/sandbox-w/g"
    fi
    # On Linux, write allows the change of the mode and of the times
    # (chown with no change first, #172), the same owner again (the
    # sandbox refuses chown()), and net allows a Unix socket.
    if [ "$os" = linux ]; then
        BEAM_COM_ALLOW="write=$dir/sandbox-w;net"
        export BEAM_COM_ALLOW
        check sandbox_none.com 'write: ok@@chmod: ok@@touch: ok@@owner: ok@@unix: ok@@done' \
            write "$dir/sandbox-w/f" chmod "$dir/sandbox-w/f" touch "$dir/sandbox-w/f" \
            owner "$dir/sandbox-w/f" unix
        BEAM_COM_ALLOW="write=$dir/sandbox-w"
        check sandbox_none.com 'unix: error eperm@@done' unix
        unset BEAM_COM_ALLOW
    fi
    rm -rf "$dir/sandbox-w"
    # Landlock on Linux: the ABI with BEAM_COM_VERBOSE, and a warning on a
    # kernel without it (BEAM_COM_NO_LANDLOCK=1 acts as one, issue 171).
    if [ "$os" = linux ]; then
        BEAM_COM_ALLOW='read=/etc;net'
        export BEAM_COM_ALLOW
        if [ "$landlock" = 1 ]; then
            check sandbox_none.com 'Landlock ABI [1-9]' read /etc/hosts
        else
            check sandbox_none.com 'warning: the kernel has no Landlock@@read: ok' read /etc/hosts
        fi
        # Without Landlock, the check of the paths in the calls of the C
        # library limits the paths (EACCES). The kernel here has Landlock,
        # so the link to /etc/hosts shows that the check of the C library
        # refuses it by its name, where Landlock follows it.
        rm -f "$dir/sandbox-link"
        ln -s /etc/hosts "$dir/sandbox-link"
        BEAM_COM_ALLOW="read=/etc/hosts;net"
        BEAM_COM_NO_LANDLOCK=1
        export BEAM_COM_ALLOW BEAM_COM_NO_LANDLOCK
        check sandbox_none.com 'warning: the kernel has no Landlock@@read: ok@@read: error eacces@@done' \
            read /etc/hosts read "$dir/sandbox-link"
        unset BEAM_COM_NO_LANDLOCK BEAM_COM_ALLOW
        rm -f "$dir/sandbox-link"
    fi
    # -N: the file of SSL_CERT_FILE also, for public_key.
    if [ -f "$dir/ca-one.pem" ]; then
        SSL_CERT_FILE=$dir/ca-one.pem
        export SSL_CERT_FILE
        check sandbox_net.com "$env" read "$dir/ca-one.pem" read "$dir/beam.com"
        unset SSL_CERT_FILE
    fi
    # The sandbox of Windows (c_src/cosmo/beam_com_fs.c), on Linux with
    # BEAM_COM_WINDOWS_SANDBOX=1. Its check uses the name, so a link out
    # of the rules gets EACCES, where Landlock follows the link to
    # /etc/hosts. Without net, a socket gets EACCES (the wrap), not EPERM
    # (pledge).
    if [ "$os" = linux ]; then
        rm -rf "$dir/sandbox-w" "$dir/sandbox-link"
        mkdir "$dir/sandbox-w"
        ln -s /etc/hosts "$dir/sandbox-link"
        BEAM_COM_ALLOW="read=/etc;write=$dir/sandbox-w" BEAM_COM_WINDOWS_SANDBOX=1
        export BEAM_COM_ALLOW BEAM_COM_WINDOWS_SANDBOX
        check sandbox_none.com 'read: ok@@read: error eacces@@write: ok@@write: error eacces@@listen: error eacces@@done' \
            read /etc/hosts read "$dir/sandbox-link" write "$dir/sandbox-w/new.txt" \
            write "$dir/sandbox-w/../sandbox.tmp" listen
        unset BEAM_COM_WINDOWS_SANDBOX
        # Without Landlock, this is the check of the C library again.
        if [ "$landlock" = 1 ]; then
            check sandbox_none.com 'read: ok@@read: ok@@listen: error eperm@@done' \
                read /etc/hosts read "$dir/sandbox-link" listen
        else
            check sandbox_none.com 'read: ok@@read: error eacces@@listen: error eacces@@done' \
                read /etc/hosts read "$dir/sandbox-link" listen
        fi
        unset BEAM_COM_ALLOW
        rm -rf "$dir/sandbox-w" "$dir/sandbox-link"
    fi
    # --allow-net=HOST,...: the resolver of beam.com and the check of each
    # address (c_src/cosmo/beam_com_net.c), on each system, with the name
    # server of tests/programs/dns_fake.erl. A name that the list does not
    # allow never goes to the name server.
    check beam.com 'wrote .*dns_fake.com' tests/programs/dns_fake.erl -o "$dir/dns_fake.com"
    if [ -f "$dir/dns_fake.com" ]; then
        chmod +x "$dir/dns_fake.com"
        $runner "$dir/dns_fake.com" > "$dir/dns_fake.out" 2>&1 &
        fake=$!
        i=0
        while ! grep -q '^dns_fake: [0-9]* [0-9]*$' "$dir/dns_fake.out" && [ $i -lt 30 ]; do
            sleep 1
            i=$((i + 1))
        done
        ports=$(sed -n 's/^dns_fake: \([0-9]*\) \([0-9]*\)$/\1 \2/p' "$dir/dns_fake.out")
        dns=${ports% *} tcp=${ports#* }
        BEAM_COM_ALLOW="net=*.test.example:$tcp" BEAM_COM_DNS_UPSTREAM=127.0.0.1:$dns
        export BEAM_COM_ALLOW BEAM_COM_DNS_UPSTREAM
        supervisor=
        if [ "$os" = linux ]; then
            supervisor='the supervisor checks the calls@@'
        fi
        check sandbox_none.com "${supervisor}"'connect a.test.example: ok@@connect big.test.example: ok@@connect alias.test.example: ok@@connect test.example: error nxdomain@@connect other.example: error nxdomain@@connect a.test.example: error eacces@@connect 127.0.0.2: error eacces@@udp 127.0.0.1: error eacces@@done' \
            connect a.test.example "$tcp" connect big.test.example "$tcp" \
            connect alias.test.example "$tcp" connect test.example "$tcp" \
            connect other.example "$tcp" connect a.test.example "$dns" \
            connect 127.0.0.2 "$tcp" udp 127.0.0.1 "$dns"
        # On Linux, without the supervisor of the calls: the wraps of the
        # libc (as on the other systems).
        if [ "$os" = linux ]; then
            BEAM_COM_NET_NO_SUPERVISOR=1
            export BEAM_COM_NET_NO_SUPERVISOR
            check sandbox_none.com 'no supervisor@@connect a.test.example: ok@@connect other.example: error nxdomain@@connect 127.0.0.2: error eacces@@done' \
                connect a.test.example "$tcp" connect other.example "$tcp" connect 127.0.0.2 "$tcp"
            unset BEAM_COM_NET_NO_SUPERVISOR
            # A program of --allow-run (python3) gets the host list from
            # the supervisor, with the address that the VM resolved.
            if command -v python3 >/dev/null; then
                BEAM_COM_ALLOW="net=*.test.example:$tcp;run=python3"
                check sandbox_none.com 'the supervisor checks the calls@@connect a.test.example: ok@@pyconnect 127.0.0.1: ok@@pyconnect 127.0.0.2: error PermissionError@@pyconnect 127.0.0.1: error PermissionError@@done' \
                    connect a.test.example "$tcp" pyconnect 127.0.0.1 "$tcp" \
                    pyconnect 127.0.0.2 "$tcp" pyconnect 127.0.0.1 "$dns"
            fi
        fi
        unset BEAM_COM_ALLOW BEAM_COM_DNS_UPSTREAM
        kill "$fake" 2>/dev/null
        wait "$fake" 2>/dev/null
        cat "$dir/dns_fake.out"
        if grep -q 'asked other.example' "$dir/dns_fake.out" ||
           grep -q 'asked test.example' "$dir/dns_fake.out" ||
           ! grep -q 'asked a.test.example' "$dir/dns_fake.out"; then
            echo "FAIL: dns_fake.com: the names that the resolver asked"
            fail=1
            failed="$failed
  dns_fake.com: the names that the resolver asked"
        else
            echo "PASS: dns_fake.com"
        fi
    fi
fi

# Hex packages (from hex.pm, so this needs the network): hexweb needs
# cowboy (with cowlib and ranch) and jsx. The first build resolves the
# versions and writes rebar.lock; the second one uses rebar.lock and the
# cache, and does not write it again.
hexweb='hexweb: content-type application/json@@hexweb: hello BEAM.com; cowboy-[0-9.]* cowlib-[0-9.]* jsx-[0-9.]* ranch-[0-9.]*$'
if [ -d examples ]; then
    rm -f examples/hexweb/rebar.lock
    check beam.com 'wrote .*rebar.lock@@wrote .*hexweb.com@@applications: .*cowboy.*cowlib.*ranch.*jsx' \
        examples/hexweb -o "$dir/hexweb.com"
    [ -f "$dir/hexweb.com" ] && check hexweb.com "$hexweb"
    if [ -f examples/hexweb/rebar.lock ]; then
        check beam.com 'wrote .*hexweb2.com' examples/hexweb -o "$dir/hexweb2.com"
        if grep -q 'rebar.lock' "$tmp"; then
            echo "FAIL: the second build of hexweb wrote rebar.lock again"
            failed="$failed
  beam.com examples/hexweb: wrote rebar.lock again"
            fail=1
        fi
        rm -f examples/hexweb/rebar.lock
    fi
fi

# --target wasm32: the Workers of examples/worker (cowboy, from hex.pm).
# The runtime of the zip (the step wasm_runtime of the Makefile), else a
# stand-in; the build runs the release natively to find the modules of
# the boot.
if [ -d examples ]; then
    in_zip=$($runner "$dir/beam.com" -noshell -eval \
        'io:format("~ts", [filelib:wildcard("/zip/lib/wasm_host-*/priv/runtime/beam.wasm")]), halt().' 2>/dev/null)
    if [ -z "$in_zip" ]; then
        mkdir -p "$dir/wasm-runtime"
        printf 'stand-in' > "$dir/wasm-runtime/beam.wasm"
        printf 'stand-in' > "$dir/wasm-runtime/beam.mjs"
        BEAM_COM_WASM_RUNTIME=$dir/wasm-runtime
        export BEAM_COM_WASM_RUNTIME
    fi
    check beam.com 'wrote .*worker (the Workers worker and worker-release)@@release: worker 0.1.0@@boot: [0-9]* modules in one batch' \
        examples/worker -o "$dir/worker" --target wasm32
    unset BEAM_COM_WASM_RUNTIME
    if [ -n "$in_zip" ] && [ "$(dd if="$dir/worker/beam.wasm" bs=4 count=1 2>/dev/null | od -An -c | tr -d ' ')" != '\0asm' ]; then
        echo "FAIL: the runtime of the zip is not a WebAssembly module"
        failed="$failed
  beam.com --target wasm32: beam.wasm"
        fail=1
    fi
    for f in worker.js app-com.js runtime-id.js beam.mjs beam.wasm wrangler.jsonc worker.capnp tcp-proxy.mjs \
             durable.js wrangler.durable.jsonc global.js wrangler.global.jsonc \
             durable-global.js wrangler.durable-global.jsonc \
             deno.js deno.json browser.js browser/beam-wasm.js \
             release/app.js release/release.bin release/wrangler.jsonc; do
        if [ ! -f "$dir/worker/$f" ]; then
            echo "FAIL: --target wasm32 did not write $f"
            failed="$failed
  beam.com --target wasm32: no $f"
            fail=1
        fi
    done
    if [ "$(dd if="$dir/worker/release/release.bin" bs=7 count=1 2>/dev/null)" != BEAMFS1 ]; then
        echo "FAIL: release.bin does not start with BEAMFS1"
        failed="$failed
  beam.com --target wasm32: release.bin"
        fail=1
    fi
    rm -f examples/worker/rebar.lock
fi

# The programs of the zip (docs/PROGRAMS.md, "priv files as real files"):
# zip_programs NAME PROG PATTERN [ARGS...] builds a copy of
# tests/programs/zip_programs with PROG as priv/bin/prog into DIR/NAME.com
# (with ARGS for the build), and checks the output of the build with
# PATTERN. The program runs priv/bin/prog with open_port/2 and
# System.cmd/3, by code:priv_dir/1 and by its path in /zip.
zip_src=$(pwd)/tests/programs/zip_programs
zip_fail() {
    echo "FAIL: $1"
    fail=1
    failed="$failed
  $1"
}
zip_programs() {
    zname=$1 zprog=$2 zpattern=$3
    shift 3
    rm -rf "$dir/$zname" "$dir/$zname.com"
    cp -R "$zip_src" "$dir/$zname"
    rm -rf "$dir/$zname/_build"
    mkdir -p "$dir/$zname/priv/bin"
    cp "$zprog" "$dir/$zname/priv/bin/prog"
    chmod 755 "$dir/$zname/priv/bin/prog"
    zlimit=$limit
    limit=600
    check beam.com "$zpattern" "$dir/$zname" "$@" -o "$dir/$zname.com"
    limit=$zlimit
    rm -rf "$dir/$zname"
}

# Elixir: a one-file program, and a Mix project with a Hex package in
# Elixir (jason, from hex.pm) and config/config.exs.
greeter_ex='greeter_ex: Hello from config/config.exs (1)@@greeter_ex: Hello from config/config.exs (2)@@greeter_ex: json {.*"elixir":"1\.[0-9.]*".*}@@greeter_ex: decoded 1\.'
if [ -d examples ]; then
    check beam.com 'wrote .*elixir_check.com@@applications: .*elixir' \
        tests/programs/elixir_check.ex -o "$dir/elixir_check.com"
    if [ -f "$dir/elixir_check.com" ]; then
        check elixir_check.com 'elixir: 1\.[0-9]*\.[0-9]* on OTP 29@@args: \["a", "b c", "日本"\]@@sum: 5050@@upcase: BEAM.COM' a "b c" 日本
        check_status 127 elixir_check.com '\*\* (RuntimeError) boom' raise
    fi
    rm -f examples/greeter_ex/mix.lock
    check beam.com 'wrote .*mix.lock@@wrote .*greeter_ex.com@@applications: .*jason' \
        examples/greeter_ex -o "$dir/greeter_ex.com"
    [ -f "$dir/greeter_ex.com" ] && check greeter_ex.com "$greeter_ex"
    rm -f examples/greeter_ex/mix.lock
    # A Mix project with config/runtime.exs: Mix makes the release
    # (beam_com_mix), and the program reads config/runtime.exs at its
    # start. It has no deps, so it needs no network.
    limit_saved=$limit
    limit=600
    check beam.com 'Mix gets the deps of tests/programs/runtime_check and makes its release (config/runtime.exs)@@wrote .*runtime_check.com@@applications: .*runtime_check' \
        tests/programs/runtime_check -o "$dir/runtime_check.com"
    limit=$limit_saved
    rm -rf tests/programs/runtime_check/_build
    if [ -f "$dir/runtime_check.com" ]; then
        RUNTIME_CHECK_GREETING="hello from config/runtime.exs"
        export RUNTIME_CHECK_GREETING
        check runtime_check.com 'runtime_check: hello from config/runtime.exs@@runtime_check: build from config/config.exs'
        unset RUNTIME_CHECK_GREETING
    fi
    # The programs of the zip: a small echo program that cc compiles here
    # (not /bin/echo: the echo of uutils of Ubuntu 26.04 refuses a name
    # that is not the name of a tool) in priv/bin, in a Mix release
    # (config/runtime.exs) and in a plain Mix project. On Linux,
    # the program runs from a memfd, with no file in the cache. With
    # BEAM_COM_MEMFD=0, and on the other systems, it runs from its copy
    # CACHE/bin/SHA256/prog: one copy, the same file at the next run, and
    # one whole file for two runs at the same time. A cache directory that
    # other users can write, and a sandbox whose --allow-run does not name
    # the program, give an error and run nothing. The cache is in DIR.
    zecho=$(cd "$dir" && pwd)/zip_echo
    printf '%s\n' '#include <stdio.h>' \
        'int main(int argc, char **argv) {' \
        '    for (int i = 1; i < argc; i++) printf(i > 1 ? " %s" : "%s", argv[i]);' \
        '    printf("\n");' \
        '    return 0;' \
        '}' > "$zecho.c"
    rm -f "$zecho"
    if ! cc -std=c99 -o "$zecho" "$zecho.c"; then
        zip_fail "cc: no program for the check of the programs of the zip"
    fi
    if [ -x "$zecho" ]; then
        zcache=$(cd "$dir" && pwd)/zip-cache
        rm -rf "$zcache"
        BEAM_COM_CACHE=$zcache
        export BEAM_COM_CACHE
        zip_programs zip_rel "$zecho" \
            'Mix gets the deps of .*zip_rel and makes its release (config/runtime.exs)@@wrote .*zip_rel.com'
        zip_programs zip_plain "$zecho" 'wrote .*zip_plain.com' --tool mix
        # The Mix tools of the builds put their links in CACHE/bin.
        rm -rf "$zcache"
        zline='zip_programs: zip port 0 hello zip (@@zip_programs: zip cmd 0 hello zip ('
        zprog=/zip/lib/zip_programs-0.1.0/priv/bin/prog
        if [ -f "$dir/zip_rel.com" ]; then
            if [ "$os" = linux ]; then
                check zip_rel.com "$zline@@$zprog runs from a memfd" hello zip
                if [ -n "$(ls "$zcache/bin" 2>/dev/null)" ]; then
                    zip_fail "zip_rel.com: the run from a memfd wrote a file in $zcache/bin"
                fi
                BEAM_COM_MEMFD=0
                export BEAM_COM_MEMFD
            fi
            check zip_rel.com "$zline@@$zprog runs from $zcache/bin/[0-9a-f]*/prog" hello zip
            zcopy=$(ls -d "$zcache"/bin/*/prog 2>/dev/null)
            zls=$(ls -lid $zcopy 2>/dev/null)
            check zip_rel.com "$zline" hello zip
            if [ "$(echo "$zcopy" | grep -c .)" != 1 ] || [ "$(ls -lid $zcopy 2>/dev/null)" != "$zls" ]; then
                zip_fail "zip_rel.com: not one copy in $zcache/bin, or the second run wrote it again: [$zcopy] [$zls] [$(ls -lid $zcopy 2>&1)]"
            else
                echo "PASS: zip_rel.com: one copy, and the second run used it: $zls"
            fi
            # Two runs at the same time make the first copy.
            rm -rf "$zcache"
            BEAM_COM_VERBOSE=1 $runner "$dir/zip_rel.com" hello zip > "$tmp.z1" 2>&1 &
            z1=$!
            BEAM_COM_VERBOSE=1 $runner "$dir/zip_rel.com" hello zip > "$tmp.z2" 2>&1 &
            z2=$!
            wait "$z1"
            wait "$z2"
            cat "$tmp.z1" "$tmp.z2"
            zleft=$(cd "$zcache/bin" 2>/dev/null && ls -A ./*/)
            if grep -q 'zip_programs: zip cmd 0 hello zip (' "$tmp.z1" &&
               grep -q 'zip_programs: zip cmd 0 hello zip (' "$tmp.z2" && [ "$zleft" = prog ]; then
                echo "PASS: zip_rel.com: two runs at the same time, one copy"
            else
                zip_fail "zip_rel.com: two runs at the same time (files: $zleft)"
            fi
            rm -f "$tmp.z1" "$tmp.z2"
            # A cache directory that other users can write.
            chmod 777 "$zcache/bin"
            check zip_rel.com 'another user can write it@@zip_programs: zip port 13 @@zip_programs: zip cmd 13 ' hello zip
            if grep -q ' 0 hello zip' "$tmp"; then
                zip_fail "zip_rel.com: a program ran from a cache that other users can write"
            fi
            chmod 700 "$zcache/bin"
            # The sandbox: --allow-run with the /zip path of the program.
            BEAM_COM_ALLOW='read;run=/bin/true'
            export BEAM_COM_ALLOW
            check zip_rel.com "$zprog: --allow-run does not name this program@@zip_programs: zip port 13 " hello zip
            if grep -q ' 0 hello zip' "$tmp"; then
                zip_fail "zip_rel.com: --allow-run=/bin/true ran a program of the zip"
            fi
            BEAM_COM_ALLOW="read;run=$zprog"
            check zip_rel.com "$zline@@--allow-run: $zprog is $zcache/bin/" hello zip
            unset BEAM_COM_ALLOW BEAM_COM_MEMFD
        fi
        if [ -f "$dir/zip_plain.com" ]; then
            check zip_plain.com "zip_programs: priv port 0 hello zip (@@zip_programs: priv cmd 0 hello zip (@@$zline" hello zip
        fi
        unset BEAM_COM_CACHE
        rm -rf "$zcache" "$dir/zip_rel.com" "$dir/zip_plain.com"
    fi
    rm -f "$zecho" "$zecho.c"
    # Run mode with a Mix project whose build writes a file in priv/: the
    # alias assets.deploy of tests/programs/rebuild_check writes a new
    # time, as phx.digest of Phoenix does. The second run must not build
    # again. A change of a source file builds again. The copy and the
    # cache are in DIR, not in the repository and not in the home.
    rm -rf "$dir/rebuild_check" "$dir/run-cache"
    cp -R tests/programs/rebuild_check "$dir/"
    BEAM_COM_CACHE=$dir/run-cache
    export BEAM_COM_CACHE
    limit_saved=$limit
    limit=600
    rebuild_line='Mix gets the deps of .*rebuild_check and makes its release (the alias assets.deploy)'
    check beam.com "$rebuild_line@@^rebuild_check: v1\$" "$dir/rebuild_check"
    if [ ! -f "$dir/rebuild_check/priv/static/stamp.txt" ]; then
        echo "FAIL: the build of rebuild_check did not run its alias assets.deploy"
        fail=1
        failed="$failed
  beam.com $dir/rebuild_check: no priv/static/stamp.txt"
    fi
    check beam.com '^rebuild_check: v1$' "$dir/rebuild_check"
    if grep -q 'Mix gets the deps' "$tmp"; then
        echo "FAIL: run mode built rebuild_check again with no change"
        fail=1
        failed="$failed
  beam.com $dir/rebuild_check: built again with no change"
    else
        echo "PASS: run mode did not build rebuild_check again"
    fi
    cat > "$dir/rebuild_check/lib/rebuild_check.ex" <<'EOF'
defmodule RebuildCheck do
  @moduledoc "Writes one line, then stops the program (after a change)."
  use Application

  def start(_type, _args) do
    IO.puts("rebuild_check: v2")
    System.halt(0)
  end
end
EOF
    check beam.com "$rebuild_line@@^rebuild_check: v2\$" "$dir/rebuild_check"
    limit=$limit_saved
    unset BEAM_COM_CACHE
    rm -rf "$dir/rebuild_check" "$dir/run-cache"
    # A command line Mix project (escript main_module) with
    # config/runtime.exs: the builder of a plain Mix project makes the
    # file, with a warning, and the file runs main/1. With one more reason
    # for Mix (--tool mix-release, or the alias assets.deploy), the build
    # stops and writes no file.
    rm -f "$dir/escript_check.com" "$dir/escript_never.com"
    plain_line='only the builder of a plain Mix project reads'
    check beam.com "warning: tests/programs/escript_check: $plain_line the escript main_module of mix.exs@@the program does not have config/runtime.exs@@wrote .*escript_check.com" \
        tests/programs/escript_check -o "$dir/escript_check.com"
    rm -rf tests/programs/escript_check/_build
    if [ -f "$dir/escript_check.com" ]; then
        check escript_check.com '^escript_check: args \["a", "b"\]$@@^escript_check: greeting none$' a b
    fi
    check_status 1 beam.com "$plain_line the escript main_module of mix.exs, and the project needs Mix (--tool mix-release)" \
        tests/programs/escript_check --tool mix-release -o "$dir/escript_never.com"
    check_status 1 beam.com "$plain_line --main, and the project needs Mix (the alias assets.deploy)" \
        tests/programs/rebuild_check --main RebuildCheck -o "$dir/escript_never.com"
    # A wrong build of rebuild_check writes _build and priv/ there.
    rm -rf tests/programs/escript_check/_build tests/programs/rebuild_check/_build \
        tests/programs/rebuild_check/priv
    if [ -e "$dir/escript_never.com" ]; then
        echo "FAIL: a build that stops wrote escript_never.com"
        fail=1
        failed="$failed
  beam.com --tool mix-release or --main: wrote escript_never.com"
    fi
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
# The SHA-1 check of the git client: the helper git_sha1dc in the file
# (c_src/cosmo/beam_com_sha1dc.c) finds the SHA-1 collisions.
if [ -d examples ]; then
    check beam.com 'git_sha1dc_check: 4 vectors have the mark, the good objects pass' \
        escript tests/programs/git_sha1dc_check.escript
fi
# A Unix socket with a short path (C53 of docs/UPSTREAM.md): bind() of
# Cosmopolitan refuses an address of fewer than 16 bytes, and the wrap of
# bind() (c_src/cosmo/beam_com_net.c) makes it longer. A server and a
# client talk through a stream socket with a path of 1 byte and of 14
# bytes, and through two datagram sockets.
cat > "$tmp.unix.escript" <<'ESCRIPT'
#!/usr/bin/env escript
main(_) ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                        "unix_socket." ++ os:getpid()),
    ok = file:make_dir(Dir),
    ok = file:set_cwd(Dir),
    Results = [stream("s"), stream("s2345678901234"), datagram("d", "e")],
    [file:delete(F) || F <- ["s", "s2345678901234", "d", "e"]],
    ok = file:del_dir(Dir),
    io:format("unix socket: ~ts~n", [lists:join(", ", Results)]).

stream(Path) ->
    Result = try
                 {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ifaddr, {local, Path}}]),
                 {ok, C} = gen_tcp:connect({local, Path}, 0, [binary, {active, false}]),
                 {ok, A} = gen_tcp:accept(L, 5000),
                 ok = gen_tcp:send(C, <<"hello">>),
                 {ok, <<"hello">>} = gen_tcp:recv(A, 5, 5000),
                 [gen_tcp:close(S) || S <- [C, A, L]],
                 "ok"
             catch error:{badmatch, Reason} -> io_lib:format("~p", [Reason])
             end,
    [Path, " ", Result].

datagram(Path1, Path2) ->
    Result = try
                 {ok, S1} = gen_udp:open(0, [binary, {active, false}, {ifaddr, {local, Path1}}]),
                 {ok, S2} = gen_udp:open(0, [binary, {active, false}, {ifaddr, {local, Path2}}]),
                 ok = gen_udp:send(S2, {local, Path1}, 0, <<"hello">>),
                 {ok, {_, _, <<"hello">>}} = gen_udp:recv(S1, 0, 5000),
                 [gen_udp:close(S) || S <- [S1, S2]],
                 "ok"
             catch error:{badmatch, Reason} -> io_lib:format("~p", [Reason])
             end,
    ["datagram ", Result].
ESCRIPT
check beam.com '^unix socket: s ok, s2345678901234 ok, datagram ok$' escript "$tmp.unix.escript"
rm -f "$tmp.unix.escript"
check beam.com '^55$' elixir -e 'IO.puts(Enum.sum(1..10))'
# The errno names of the BEAM on each system: ELOOP gave errno_40 on
# Linux and errno_62 on macOS (C35 of docs/UPSTREAM.md).
rm -f "$tmp.loop1" "$tmp.loop2"
ln -s "$tmp.loop2" "$tmp.loop1"
ln -s "$tmp.loop1" "$tmp.loop2"
check beam.com '^eloop$' elixir -e "{:error, e} = File.read(\"$tmp.loop1\"); IO.puts(e)"
rm -f "$tmp.loop1" "$tmp.loop2"
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
    # The tools name the watcher of the file for file_system: a link
    # inotifywait (a script mac_listener on macOS) in the cache. Without a
    # path, the watcher shows its usage. Not on NetBSD, whose kernel does
    # not start an APE file by a link.
    if [ "$os" != netbsd ]; then
        case $os in darwin) watcher=mac_listener var=FSMAC ;; *) watcher=inotifywait var=FSINOTIFY ;; esac
        check elixir.com "^usage: $watcher " -e "{out, 1} = System.cmd(System.fetch_env!(\"FILESYSTEM_${var}_EXECUTABLE_FILE\"), [], stderr_to_stdout: true); IO.write(out)"
        # Mix runs rebar3 as "#!/usr/bin/env escript". With no escript in
        # PATH (as here), the tools put the program escript of the cache
        # at the start of PATH.
        chmod +x "$tmp.escript"
        check elixir.com '^escript: \["x"\] 1$' -e "{out, 0} = System.cmd(\"$tmp.escript\", [\"x\"]); IO.write(out)"
    fi
    printf 'defmodule ToolsC do\n  def f, do: :ok\nend\n' > tools_c.ex
    check elixirc.com '' tools_c.ex -o out
    [ -f out/Elixir.ToolsC.beam ] || { echo "FAIL: elixirc wrote no beam file"; fail=1; failed="$failed
  elixirc.com: no out/Elixir.ToolsC.beam"; }
    check mix.com 'creating mix.exs' new hello
    cd hello
    check mix.com '2 passed' test
    # Coverage: cover, of the application tools.
    check mix.com 'Generating cover results@@100\.00% | Total' test --cover
    check mix '' format --check-formatted
    check elixir '^world$' -S mix run -e 'IO.puts(Hello.hello())'
    # An implementation of a protocol of Elixir: Mix consolidates the
    # protocols of Elixir too (patches/elixir/0002), with their debug
    # information (step_bundle of scripts/steps.sh).
    printf 'defmodule Hello.Box do\n  defstruct [:text]\nend\n\ndefimpl String.Chars, for: Hello.Box do\n  def to_string(%%{text: t}), do: t\nend\n' > lib/box.ex
    check mix '^true true box$' run -e 'IO.puts("#{Protocol.consolidated?(String.Chars)} #{Protocol.consolidated?(Enumerable)} #{%Hello.Box{text: "box"}}")'
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
        net_check mix '' local.hex --force
        net_check mix '' local.rebar --force
        sed 's/# {:dep_from_hexpm, "~> 0.3.0"},/{:jason, "~> 1.4"}, {:telemetry, "~> 1.3"},/' mix.exs > mix.exs.new
        mv mix.exs.new mix.exs
        net_check mix 'jason@@telemetry' deps.get
        check mix '^{"a":1}$@@^telemetry$' run -e 'IO.puts(Jason.encode!(%{a: 1})); IO.puts(:telemetry.module_info(:module))'
        # The NIFs of exqlite, bcrypt_elixir and argon2_elixir are in beam.com: the
        # packages (of the versions in "beam.com --version") compile without
        # make and a C compiler (MAKE is the program make in the cache,
        # which does nothing for them), with no NIF file in priv, and
        # load_nif/2 finds the static NIFs. esqlite (in the zip) and
        # exqlite use the same SQLite. Not on NetBSD (see the watcher).
        linked_nifs
        if [ "$os" != netbsd ] && [ -n "$exqlite_vsn" ] && [ -n "$bcrypt_vsn" ] &&
           [ -n "$argon2_vsn" ]; then
            sed "s/{:jason, \"~> 1.4\"},/{:jason, \"~> 1.4\"}, {:exqlite, \"$exqlite_vsn\"}, {:bcrypt_elixir, \"$bcrypt_vsn\"}, {:argon2_elixir, \"$argon2_vsn\"},/" mix.exs > mix.exs.new
            mv mix.exs.new mix.exs
            net_check mix 'exqlite@@bcrypt_elixir@@argon2_elixir' deps.get
            check mix 'Generated exqlite app@@Generated bcrypt_elixir app@@Generated argon2_elixir app' deps.compile
            no_nif_build
            check mix '^exqlite: {:row, \["3\.[0-9.]*", 2\]}$@@^bcrypt: true$@@^argon2: true$' run -e '{:ok, c} = Exqlite.Sqlite3.open(":memory:"); {:ok, s} = Exqlite.Sqlite3.prepare(c, "select sqlite_version(), 1 + 1"); IO.puts("exqlite: #{inspect(Exqlite.Sqlite3.step(c, s))}"); IO.puts("bcrypt: #{Bcrypt.verify_pass("pw", Bcrypt.hash_pwd_salt("pw"))}"); IO.puts("argon2: #{Argon2.verify_pass("pw", Argon2.hash_pwd_salt("pw"))}")'
            check elixir.com '^esqlite: \[\["3\.[0-9.]*",4\]\]$@@^exqlite: {:row, \["3\.[0-9.]*", 2\]}$' -pa _build/dev/lib/exqlite/ebin -e '{:ok, d} = :esqlite3.open(~c":memory:"); IO.puts("esqlite: #{:json.encode(:esqlite3.q(d, "select sqlite_version(), 2 + 2"))}"); {:ok, c} = Exqlite.Sqlite3.open(":memory:"); {:ok, s} = Exqlite.Sqlite3.prepare(c, "select sqlite_version(), 1 + 1"); IO.puts("exqlite: #{inspect(Exqlite.Sqlite3.step(c, s))}")'
        fi
    fi
    cd "$here"
    rm -f "$dir/mix" "$dir/iex" "$dir/elixir" "$dir/escript" \
        "$dir/mix.com" "$dir/iex.com" "$dir/elixir.com" "$dir/elixirc.com"
    rm -rf "$work"
    dir=$dir_rel runner=$runner_rel
fi

# Phoenix from source, with the tools: a new app (mix phx.new) with
# SQLite (ecto_sqlite3, and so exqlite) and phx.gen.auth (bcrypt_elixir),
# its deps from hex.pm and GitHub (heroicons is a git dep), the database
# (ecto.migrate), an account with a password, and "iex.com -S mix
# phx.server" serves the start page and makes an account (a POST of the
# registration form). exqlite and bcrypt_elixir compile without make (see
# the tools above); their versions are the ones of the NIFs in beam.com.
# Linux only: it needs git, curl and the network (the esbuild and
# tailwind watchers download their programs).
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
    net_check mix.com '' local.hex --force
    # A fixed phx_new: a new version can give other deps (the checks
    # below name the git deps). Keep it equal to tests/run.ps1.
    net_check mix.com 'phx_new' archive.install hex phx_new 1.8.16 --force
    check mix.com 'creating hello/mix.exs' phx.new hello --database sqlite3 --no-install
    linked_nifs
    if [ -d hello ] && [ -n "$exqlite_vsn" ] && [ -n "$bcrypt_vsn" ]; then
        cd hello
        sed "s/{:ecto_sqlite3, \"[^\"]*\"},/& {:exqlite, \"$exqlite_vsn\"},/" mix.exs > mix.exs.new
        mv mix.exs.new mix.exs
        net_check mix.com 'phoenix@@exqlite' deps.get
        check mix.com 'creating lib/hello/accounts.ex' phx.gen.auth Accounts User users --no-live
        sed "s/{:bcrypt_elixir, \"[^\"]*\"}/{:bcrypt_elixir, \"$bcrypt_vsn\"}/" mix.exs > mix.exs.new
        mv mix.exs.new mix.exs
        net_check mix.com 'bcrypt_elixir' deps.get
        check mix.com 'Migrated ' ecto.migrate
        no_nif_build
        check mix.com '^auth: true true$' run -e 'alias Hello.Accounts; e = "u#{System.unique_integer([:positive])}@example.com"; {:ok, u} = Accounts.register_user(%{email: e}); {:ok, _} = Accounts.update_user_password(u, %{password: "a long password"}); IO.puts("auth: #{Accounts.get_user_by_email_and_password(e, "a long password").id == u.id} #{Accounts.get_user_by_email_and_password(e, "wrong password") == nil}")'
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
        grep -v '^ *$' "$tmp.phx" | head -20
        if [ -n "$served" ]; then
            echo "PASS: iex.com -S mix phx.server (after $((i * 2)) s)"
        else
            echo "FAIL: iex.com -S mix phx.server did not serve the start page"
            fail=1
            failed="$failed
  iex.com -S mix phx.server: no start page on http://127.0.0.1:4123/"
        fi
        # A new account: the form (with its CSRF token and cookie), then
        # the POST, which inserts the user and redirects to the log-in page.
        echo "==> POST /users/register"
        curl -s -c "$tmp.cookies" http://127.0.0.1:$PORT/users/register > "$tmp.form"
        token=$(sed -n 's/.*name="_csrf_token"[^>]* value="\([^"]*\)".*/\1/p' "$tmp.form" | head -n 1)
        registered=$(curl -s -b "$tmp.cookies" -o /dev/null -w '%{http_code} %{redirect_url}' \
            --data-urlencode "_csrf_token=$token" --data-urlencode 'user[email]=new@example.com' \
            http://127.0.0.1:$PORT/users/register)
        echo "$registered"
        case $registered in
            "302 "*/users/log-in) echo "PASS: POST /users/register" ;;
            *) echo "FAIL: POST /users/register"
               fail=1
               failed="$failed
  POST /users/register: $registered (expected a redirect to /users/log-in)" ;;
        esac
        rm -f "$tmp.cookies" "$tmp.form"
        unset PORT
        # Stop the VM (the program of the pipeline), then the sleep.
        pkill -f "$dir/iex.com" 2>/dev/null
        kill "$phx" 2>/dev/null
        pkill -f "^sleep 300$" 2>/dev/null
        wait "$phx" 2>/dev/null
        # The watchers of the server download tailwind and esbuild into
        # _build, and the stop above can come before the chmod of a
        # download. Then the file stays, and the next install skips it
        # ("eacces" at the open of the port). Remove such a file.
        for f in _build/tailwind-* _build/esbuild-*; do
            if [ -f "$f" ] && [ ! -x "$f" ]; then
                echo "remove $f: the stop of the server came before its chmod"
                rm -f "$f"
            fi
        done
        # The same app in one file, with no Mix task first: Mix makes the
        # release (beam_com_mix), for config/runtime.exs, the git deps
        # (heroicons, daisyui), the compilers and assets.deploy. The git
        # deps come again with the git client of beam.com
        # (BEAM_COM_GIT=client), as on a computer with no git program.
        rm -rf deps/heroicons deps/daisyui
        BEAM_COM_GIT=client
        export BEAM_COM_GIT
        net_check beam.com 'Mix gets the deps of \. and makes its release (config/runtime.exs, deps that are not Hex packages: heroicons daisyui@@Check your digested files@@wrote .*hello.com@@applications: .*hello .*phoenix' \
            . -o "$dir/hello.com"
        unset BEAM_COM_GIT
        if [ -f deps/heroicons/.git/HEAD ] && [ ! -d deps/heroicons/.git/objects/pack ]; then
            echo "PASS: the git client of beam.com got heroicons"
        else
            echo "FAIL: the git client of beam.com did not get heroicons"
            fail=1
            failed="$failed
  BEAM_COM_GIT=client: deps/heroicons is not a checkout of the git client of beam.com"
        fi
        if [ -f "$dir/hello.com" ]; then
            chmod +x "$dir/hello.com"
            echo "==> hello.com"
            PHX_SERVER=true PORT=4124 DATABASE_PATH="$work/hello_prod.db" \
                SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
                $runner "$dir/hello.com" > "$tmp.phx" 2>&1 &
            phx=$!
            served=
            i=0
            while [ $i -lt 60 ]; do
                sleep 1
                i=$((i + 1))
                if curl -s http://127.0.0.1:4124/ 2>/dev/null | grep -q 'Phoenix Framework'; then
                    served=yes
                    break
                fi
            done
            grep -v '^ *$' "$tmp.phx" | head -20
            css=$(curl -s http://127.0.0.1:4124/ 2>/dev/null | sed -n 's/.*href="\(\/assets\/css\/app-[^"]*\)".*/\1/p' | head -n 1)
            if [ -n "$served" ] && [ -n "$css" ] &&
               [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4124$css")" = 200 ]; then
                echo "PASS: hello.com serves the start page and $css (after $i s)"
            else
                echo "FAIL: hello.com did not serve the start page and its digested CSS"
                fail=1
                failed="$failed
  hello.com: no start page or digested CSS on http://127.0.0.1:4124/"
            fi
            kill "$phx" 2>/dev/null
            wait "$phx" 2>/dev/null
        fi
        # The tailwind program of the build (one file of Bun, which reads
        # its own file) in priv of a program: it runs from the zip, from a
        # memfd and from its copy in the cache.
        tw=$(ls _build/tailwind-* 2>/dev/null | head -n 1)
        if [ -n "$tw" ]; then
            BEAM_COM_CACHE=$work/zip-cache
            export BEAM_COM_CACHE
            zip_programs zip_tw "$tw" 'Mix gets the deps of .*zip_tw and makes its release@@wrote .*zip_tw.com'
            if [ -f "$dir/zip_tw.com" ]; then
                # The output of tailwind has the escapes of the colors.
                tline='zip_programs: zip port 0 .*tailwindcss .*v4@@zip_programs: zip cmd 0 .*tailwindcss .*v4'
                check zip_tw.com "$tline@@runs from a memfd" --help
                BEAM_COM_MEMFD=0
                export BEAM_COM_MEMFD
                check zip_tw.com "$tline@@runs from $work/zip-cache/bin/" --help
                check zip_tw.com "$tline" --help
                unset BEAM_COM_MEMFD
            fi
            unset BEAM_COM_CACHE
            rm -f "$dir/zip_tw.com"
        else
            echo "FAIL: no _build/tailwind-* in the Phoenix app"
            fail=1
            failed="$failed
  Phoenix: no _build/tailwind-* for the check of a program of the zip"
        fi
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
    echo old > "$wdir/sub/old.txt"
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
    echo more >> "$wdir/sub/old.txt"
    sleep 2
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    if grep -q "^$wdir/|CREATE|a.txt$" "$tmp.watch" &&
       grep -q "^$wdir/|CREATE,ISDIR|new$" "$tmp.watch" &&
       grep -q "^$wdir/new/|CREATE|b.txt$" "$tmp.watch" &&
       grep -q "^$wdir/|DELETE|a.txt$" "$tmp.watch" &&
       grep -q "^$wdir/sub/|MODIFY|old.txt$" "$tmp.watch"; then
        echo "PASS: beam.com inotifywait"
    else
        echo "FAIL: beam.com inotifywait"
        fail=1
        failed="$failed
  beam.com inotifywait: missing events"
    fi
    rm -rf "$wdir"
fi

# The same watcher as mac_listener (the watcher of file_system on macOS):
# its command line and its lines ("ID<TAB>0xFLAGS=[created,isfile]<TAB>
# PATH"). It exits when its input closes, as file_system expects.
if [ -f "$dir/beam.com" ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    echo old > "$wdir/old.txt"
    echo "==> beam.com mac_listener"
    (sleep 5) | $runner "$dir/beam.com" mac_listener --latency=0.2 -F "$wdir" \
        > "$tmp.watch" 2>&1 &
    watcher=$!
    sleep 2
    echo a > "$wdir/a.txt"
    mkdir "$wdir/new"
    sleep 1
    rm "$wdir/a.txt"
    echo more >> "$wdir/old.txt"
    # The input closes after 5 seconds: the watcher must exit by itself.
    sleep 4
    if kill -0 "$watcher" 2>/dev/null; then
        kill "$watcher" 2>/dev/null
        exited=no
    else
        exited=yes
    fi
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    tab=$(printf '\t')
    if grep -q "^[0-9]*${tab}0x00010100=\[created,isfile\]${tab}$wdir/a.txt$" "$tmp.watch" &&
       grep -q "^[0-9]*${tab}0x00020100=\[created,isdir\]${tab}$wdir/new$" "$tmp.watch" &&
       grep -q "^[0-9]*${tab}0x00010200=\[removed,isfile\]${tab}$wdir/a.txt$" "$tmp.watch" &&
       grep -q "^[0-9]*${tab}0x00011000=\[modified,isfile\]${tab}$wdir/old.txt$" "$tmp.watch" &&
       [ "$exited" = yes ]; then
        echo "PASS: beam.com mac_listener"
    else
        echo "FAIL: beam.com mac_listener"
        fail=1
        failed="$failed
  beam.com mac_listener: missing events, or it did not exit ($exited)"
    fi
    rm -rf "$wdir"
fi

# Many files: the watcher finds the entry of each file in an index of the
# paths, so a comparison of n files costs O(n). With its input closed,
# mac_listener exits after its first comparison: of 80000 files, it must
# end in 20 seconds. On Linux x86_64, it takes 0.3 s, and a linear search
# for each file took 65 s (40000 files: 0.2 s and 14 s). This check runs
# on Linux only: the code is the same on each system, and the BSDs run in
# a slow VM. Then 1000 files, of which the watcher sees 500 removed and
# 500 changed: each removal moves an entry in the table, and each change
# must still come one time, with its path. A comparison during the rm
# gives no other event for a removed file (its link count is 0). The
# checks of the events wait for their lines (watch_until), not for a
# fixed time.
#
# watch_until SECONDS TEST...: run TEST each second until it passes, at
# most SECONDS times.
watch_until() {
    n=$1
    shift
    while [ "$n" -gt 0 ] && ! "$@"; do
        sleep 1
        n=$((n - 1))
    done
}
# The input of a mac_listener of a test is the FIFO $tmp.in, open for
# writes on the descriptor 3 (watch_start). watch_stop closes it, and
# mac_listener exits at the end of its input: a kill is only for a
# watcher that does not exit in 10 s.
watch_start() {
    exec 3> "$tmp.in"
}
watch_alive() {
    kill -0 "$watcher" 2>/dev/null
}
watch_gone() {
    ! watch_alive
}
watch_stop() {
    exec 3>&-
    watch_until 10 watch_gone
    watch_alive && kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    rm -f "$tmp.in"
}
if [ -f "$dir/beam.com" ] && [ "$(uname -s)" = Linux ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    i=0
    while [ $i -lt 200 ]; do
        mkdir "$wdir/d$i"
        (cd "$wdir/d$i" && awk 'BEGIN { for (j = 0; j < 400; j++) print "f" j }' | xargs touch)
        i=$((i + 1))
    done
    echo "==> beam.com mac_listener (80000 files)"
    $runner "$dir/beam.com" mac_listener "$wdir" < /dev/null > "$tmp.watch" 2>&1 &
    watcher=$!
    i=0
    while [ $i -lt 20 ] && kill -0 "$watcher" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$watcher" 2>/dev/null; then
        kill "$watcher" 2>/dev/null
        exited=no
    else
        exited=yes
    fi
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    if [ "$exited" = yes ] && [ ! -s "$tmp.watch" ]; then
        echo "PASS: beam.com mac_listener (80000 files)"
    else
        echo "FAIL: beam.com mac_listener (80000 files)"
        fail=1
        failed="$failed
  beam.com mac_listener (80000 files): no end of the comparison in 20 s ($exited), or output"
    fi
    rm -rf "$wdir"
fi
if [ -f "$dir/beam.com" ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    mkdir "$wdir/m"
    (cd "$wdir/m" && awk 'BEGIN { for (j = 0; j < 1000; j++) print "f" j }' | xargs touch)
    echo "==> beam.com mac_listener (1000 files)"
    mkfifo "$tmp.in"
    $runner "$dir/beam.com" mac_listener --latency=0.2 "$wdir" \
        < "$tmp.in" > "$tmp.watch" 2>&1 &
    watcher=$!
    watch_start
    sleep 2
    (cd "$wdir/m" && awk 'BEGIN { for (j = 0; j < 1000; j += 2) print "f" j }' | xargs rm)
    for f in $(awk 'BEGIN { for (j = 1; j < 1000; j += 2) print "f" j }'); do
        echo x >> "$wdir/m/$f"
    done
    tab=$(printf '\t')
    watch_counts() {
        removed=$(grep -c "^[0-9]*${tab}0x00010200=\[removed,isfile\]${tab}$wdir/m/f[0-9]*[02468]$" "$tmp.watch")
        modified=$(grep -c "^[0-9]*${tab}0x00011000=\[modified,isfile\]${tab}$wdir/m/f[0-9]*[13579]$" "$tmp.watch")
        [ "$removed" -ge 500 ] && [ "$modified" -ge 500 ]
    }
    watch_until 15 watch_counts
    # One more second: a change that comes two times must show.
    sleep 1
    watch_stop
    watch_counts
    others=$(grep -v "${tab}0x00020400=\[inodemetamod,isdir\]${tab}$wdir/m$" "$tmp.watch" | grep -c -v -e "removed,isfile" -e "modified,isfile")
    echo "removed $removed, modified $modified, other lines $others"
    if [ "$removed" = 500 ] && [ "$modified" = 500 ] && [ "$others" = 0 ]; then
        echo "PASS: beam.com mac_listener (1000 files)"
    else
        cat "$tmp.watch"
        echo "FAIL: beam.com mac_listener (1000 files)"
        fail=1
        failed="$failed
  beam.com mac_listener (1000 files): $removed removed and $modified changed of 500, $others other lines"
    fi
    rm -rf "$wdir"
fi

# Symbolic links in a watched tree, as inotifywait -r: the watcher follows
# a PATH that is a link (root), but no link below it. Two links to the
# root (a, b) make a walk that does not end when the watcher follows the
# links, and the link of Mix (_build/dev/lib/app/priv -> ../../../../priv)
# gives each change of priv/ a second path. A new link is an entry of its
# own (issymlink for mac_listener). The same tree for both watchers.
watch_links() {
    mkdir -p "$1/real/priv/static" "$1/real/_build/dev/lib/app"
    ln -s ../../../../priv "$1/real/_build/dev/lib/app/priv"
    ln -s . "$1/real/a"
    ln -s . "$1/real/b"
    ln -s real "$1/root"
}
watch_link_changes() {
    sleep 2
    echo x > "$1/real/priv/static/app.css"
    mkdir "$1/real/priv/new"
    sleep 1
    echo y > "$1/real/priv/new/b.txt"
    ln -s .. "$1/real/priv/new/up"
}
watch_links_inotify() {
    grep -q "^$wdir/root/priv/static/|CREATE|app.css$" "$tmp.watch" &&
        grep -q "^$wdir/root/priv/|CREATE,ISDIR|new$" "$tmp.watch" &&
        grep -q "^$wdir/root/priv/new/|CREATE|b.txt$" "$tmp.watch" &&
        grep -q "^$wdir/root/priv/new/|CREATE|up$" "$tmp.watch"
}
watch_links_mac() {
    grep -q "^[0-9]*${tab}0x00010100=\[created,isfile\]${tab}$wdir/root/priv/static/app.css$" "$tmp.watch" &&
        grep -q "^[0-9]*${tab}0x00020100=\[created,isdir\]${tab}$wdir/root/priv/new$" "$tmp.watch" &&
        grep -q "^[0-9]*${tab}0x00010100=\[created,isfile\]${tab}$wdir/root/priv/new/b.txt$" "$tmp.watch" &&
        grep -q "^[0-9]*${tab}0x00040100=\[created,issymlink\]${tab}$wdir/root/priv/new/up$" "$tmp.watch"
}
if [ -f "$dir/beam.com" ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    watch_links "$wdir"
    echo "==> beam.com inotifywait (links)"
    $runner "$dir/beam.com" inotifywait -e modify -e close_write -e moved_to \
        -e moved_from -e create -e delete -e attrib --format '%w|%e|%f' \
        --quiet -m -r "$wdir/root" > "$tmp.watch" 2>&1 &
    watcher=$!
    watch_link_changes "$wdir"
    watch_until 15 watch_links_inotify
    sleep 1
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    if watch_links_inotify &&
       ! grep -Eq "^$wdir/root/(a|b|_build|priv/new/up)/" "$tmp.watch"; then
        echo "PASS: beam.com inotifywait (links)"
    else
        echo "FAIL: beam.com inotifywait (links)"
        fail=1
        failed="$failed
  beam.com inotifywait (links): missing events, or events under a link"
    fi
    rm -rf "$wdir"
fi
if [ -f "$dir/beam.com" ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    watch_links "$wdir"
    echo "==> beam.com mac_listener (links)"
    mkfifo "$tmp.in"
    $runner "$dir/beam.com" mac_listener --latency=0.2 -F "$wdir/root" \
        < "$tmp.in" > "$tmp.watch" 2>&1 &
    watcher=$!
    watch_start
    tab=$(printf '\t')
    watch_link_changes "$wdir"
    watch_until 15 watch_links_mac
    sleep 1
    watch_stop
    cat "$tmp.watch"
    if watch_links_mac &&
       ! grep -Eq "${tab}$wdir/root/(a|b|_build|priv/new/up)/" "$tmp.watch"; then
        echo "PASS: beam.com mac_listener (links)"
    else
        echo "FAIL: beam.com mac_listener (links)"
        fail=1
        failed="$failed
  beam.com mac_listener (links): missing events, or events under a link"
    fi
    rm -rf "$wdir"
fi

# kqueue (macOS and the BSDs): a change starts the comparison at once.
# The interval is 5 seconds, so a change seen in 2 seconds comes from
# kqueue. The watcher first reports probe files, so that it surely runs
# (a slow system can take some seconds to start it); the next comparison
# of the interval is then 4 seconds or more later. On Linux, mac_listener
# does not use inotify, so the check is not made there.
case $(uname -s) in Darwin|FreeBSD|NetBSD|OpenBSD) kqueue=yes ;; *) kqueue=no ;; esac
if [ -f "$dir/beam.com" ] && [ "$kqueue" = yes ]; then
    wdir=$(mktemp -d "${TMPDIR:-/tmp}/beam_com_watch.XXXXXX")
    echo old > "$wdir/old.txt"
    echo "==> beam.com mac_listener (kqueue)"
    (sleep 25) | $runner "$dir/beam.com" mac_listener --latency=5 "$wdir" \
        > "$tmp.watch" 2>&1 &
    watcher=$!
    i=0
    while [ $i -lt 20 ] && ! grep -q probe "$tmp.watch"; do
        echo "$i" > "$wdir/probe$i"
        sleep 1
        i=$((i + 1))
    done
    echo more >> "$wdir/old.txt"
    sleep 2
    cp "$tmp.watch" "$tmp.watch2"
    # The input closes after 25 seconds: the watcher must exit by itself.
    i=0
    while [ $i -lt 40 ] && kill -0 "$watcher" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$watcher" 2>/dev/null; then
        kill "$watcher" 2>/dev/null
        exited=no
    else
        exited=yes
    fi
    wait "$watcher" 2>/dev/null
    cat "$tmp.watch"
    tab=$(printf '\t')
    if grep -q "^[0-9]*${tab}0x00011000=\[modified,isfile\]${tab}$wdir/old.txt$" "$tmp.watch2" &&
       [ "$exited" = yes ]; then
        echo "PASS: beam.com mac_listener (kqueue)"
    else
        echo "FAIL: beam.com mac_listener (kqueue)"
        fail=1
        failed="$failed
  beam.com mac_listener (kqueue): no change in 2 seconds, or it did not exit ($exited)"
    fi
    rm -rf "$wdir" "$tmp.watch2"
fi

# Distributed Erlang and remote shells (not on Windows). epmd is in the
# file, and starts only for -sname, -name or -remsh. examples/counter has
# -sname counter in its vm.args: "counter.com remote" is a shell in the
# running node, and so is "beam.com -remsh counter".
if [ -d examples ] && [ -f "$dir/beam.com" ]; then
    $runner "$dir/beam.com" epmd -kill > /dev/null 2>&1
    check beam.com 'Erlang/OTP' --version
    check_status 1 beam.com 'Cannot connect to local epmd' epmd -names
    check beam.com 'wrote .*counter.com@@applications: kernel stdlib' \
        examples/counter -o "$dir/counter.com"
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
        # stop the counter node. The node name is printed with ~s: with ~p,
        # a host name with "-" (macOS runners) is a quoted atom.
        printf 'counter:incr(), counter:incr(), io:format("value ~p on ~s~n", [counter:value(), node()]).\n' > "$tmp.remsh"
        echo "==> counter.com remote"
        if $runner "$dir/counter.com" remote < "$tmp.remsh" 2>&1 | tee "$tmp.out" | grep 'value 2 on counter@' >/dev/null; then
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
        if $runner "$dir/beam.com" -sname probe -setcookie beamcom -remsh counter < "$tmp.remsh" 2>&1 | tee "$tmp.out" | grep 'remsh 2' >/dev/null; then
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
        examples/toolbox -o "$dir/toolbox.com"
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
        examples/toolbox --main toolbox_cli -o "$dir/toolbox2.com"
    [ -f "$dir/toolbox2.com" ] && check toolbox2.com 'toolbox: Hello, Bo$' greet Bo
    check_status 1 beam.com 'toolbox_english does not export main/1' \
        examples/toolbox --main toolbox_english -o "$dir/never.com"
fi

# WebAssembly: wasm_check, and a WASI program in Go (made by CI).
wasm='wasm: add(40, 2) = 42@@wasm: trap: @@wasm: memory ok@@hello from wasi@@wasm: wasi exit code 7'
go='go: hello from wasip1, args \[one two\]@@go: BEAM_COM=1@@go: read back "written by go"@@exited with 0'
if [ -d examples ]; then
    check beam.com 'wrote .*wasm_check.b.com' \
        tests/programs/wasm_check.erl -o "$dir/wasm_check.b.com"
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
        tests/programs/wasm_tests.erl -o "$dir/wasm_tests.b.com"
    [ -f "$dir/wasm_tests.b.com" ] && check wasm_tests.b.com 'wasm_tests: all [0-9]* passed'
fi

# NIF libraries in WebAssembly (docs/NIFS.md): the application nif_check,
# with priv/nif_check.wasm and its AOT files in the zip of the program.
# BEAM_COM_NIF_DEBUG names the file that load_nif/2 loads: the AOT file of
# the CPU on Linux and macOS, and either one elsewhere (a system can refuse
# the memory of AOT code). Then the same checks with the interpreter
# (BEAM_COM_NIF_AOT=0).
if [ -d examples ]; then
    check beam.com 'wrote .*nif_check.com' tests/programs/nif_check --main nif_check -o "$dir/nif_check.com"
    if [ -f "$dir/nif_check.com" ]; then
        case $os-$(uname -m) in
            linux-x86_64) nif_file='nif_check\.x86_64\.aot$' ;;
            linux-aarch64) nif_file='nif_check\.aarch64\.aot$' ;;
            darwin-arm64) nif_file='nif_check\.aarch64\.aot$' ;;
            *) nif_file='nif_check\.[xw]' ;;
        esac
        BEAM_COM_NIF_DEBUG=1
        export BEAM_COM_NIF_DEBUG
        check nif_check.com "nif_wasm: .*$nif_file@@nif_check: all [0-9]* passed"
        BEAM_COM_NIF_AOT=0
        export BEAM_COM_NIF_AOT
        check nif_check.com 'nif_wasm: .*nif_check\.wasm$@@nif_check: all [0-9]* passed'
        unset BEAM_COM_NIF_DEBUG BEAM_COM_NIF_AOT
    fi
fi

# Native NIF objects (docs/NIFS.md): the application native_nif_check,
# with priv/native_nif_check.x86_64.o and .aarch64.o in the zip of the
# program. BEAM_COM_NIF_DEBUG names the object of the CPU that load_nif/2
# loads.
if [ -d examples ]; then
    check beam.com 'wrote .*native_nif_check.com' tests/programs/native_nif_check \
        --main native_nif_check -o "$dir/native_nif_check.com"
    if [ -f "$dir/native_nif_check.com" ]; then
        case $(uname -m) in
            x86_64 | amd64 | AMD64) nif_file='native_nif_check\.x86_64\.o$' ;;
            *) nif_file='native_nif_check\.aarch64\.o$' ;;
        esac
        BEAM_COM_NIF_DEBUG=1
        export BEAM_COM_NIF_DEBUG
        check native_nif_check.com "nif_native: .*$nif_file@@native_nif_check: all [0-9]* passed"
        unset BEAM_COM_NIF_DEBUG
    fi
fi

# assemble OUT BASE COUNT SPEC...: OUT from BASE and the COUNT files of
# the specs (NAME=FILE, or PREFIX/=DIR for each file of DIR), with
# scripts/assemble.erl.
assemble() {
    a_out=$1 a_base=$2 a_count=$3
    shift 3
    check beam.com "assemble: wrote .*${a_out##*/}: [0-9]* bytes, the length of the start; new files: $a_count\$" \
        scripts/assemble.erl -- "$a_base" "$a_out" "$@"
}

# files DIR...: the count of the regular files of each DIR.
files() {
    echo $(($(find "$@" -type f | wc -l)))
}

# The NIFs of the store as native NIF objects: vix, rusty_csv and
# ex_pdfium. store_nifs.tar.gz of CI (the job Build of build.yml) holds
# their objects for each CPU, in the tree nifs/APP-VSN of a program, the
# license texts in licenses/NAME, parts.txt and nif_needs.com.
if [ -d examples ] && [ -f "$dir/store_nifs.tar.gz" ]; then
    store=$dir/store_nifs
    rm -rf "${store:?}"
    mkdir -p "$store"
    tar -xzf "$dir/store_nifs.tar.gz" -C "$store"
    case $(uname -m) in
        x86_64 | amd64 | AMD64) cpu=x86_64 ;;
        *) cpu=aarch64 ;;
    esac
    # The program has each name that the objects of this CPU need.
    cp "$store/nif_needs.com" "$dir/nif_needs.com"
    check nif_needs.com "libex_pdfium\.$cpu\.o: ok@@librustycsv\.$cpu\.o: ok@@vix\.$cpu\.o: ok" \
        $(find "$store/nifs" -name "*.$cpu.o" | sort)
    # store_nif_check, with the objects at the paths of the packages.
    priv=tests/programs/store_nif_check/priv
    rm -rf "$priv"
    mkdir -p "$priv"
    for d in "$store"/nifs/*/; do
        cp -R "$d." "$priv/"
    done
    store_ok='store_nif_check: vix ok@@store_nif_check: rustycsv ok@@store_nif_check: ex_pdfium ok@@store_nif_check: all 3 passed'
    check beam.com 'wrote .*store_nif_check.com' tests/programs/store_nif_check \
        --main store_nif_check -o "$dir/store_nif_check.com"
    if [ -f "$dir/store_nif_check.com" ]; then
        check store_nif_check.com "$store_ok"
    fi
    # The same program, assembled by hand (scripts/assemble.erl): the
    # program with no objects, and then the objects as new files of its
    # zip, as a server streams it.
    rm -rf "$dir/store_nif_base"
    mkdir -p "$dir/store_nif_base"
    cp -R tests/programs/store_nif_check/src "$dir/store_nif_base/"
    check beam.com 'wrote .*store_nif_base.com' "$dir/store_nif_base" \
        --main store_nif_check -o "$dir/store_nif_base.com"
    assemble "$dir/store_nif_hand.com" "$dir/store_nif_base.com" "$(files "$priv")" \
        "lib/store_nif_check-1.0.0/priv/=$priv"
    if [ -f "$dir/store_nif_hand.com" ]; then
        check store_nif_hand.com "$store_ok"
    fi
    # A beam.com assembled from parts: beam.com, and the objects as NIF
    # files of beam_com (lib/beam_com/priv/nifs). It builds the Elixir
    # programs of vix, rusty_csv and ex_pdfium from hex.pm, with no static
    # NIF of them: the builder puts the objects in the priv directories of
    # the packages.
    # The license texts of the parts (PDFium) go into licenses/, as in the
    # static build, and each program of this beam.com keeps them.
    # parts.txt gives the files of each package ("PKG PREFIX/=DIR").
    specs= parts=
    while read -r pkg spec; do
        specs="$specs ${spec%%=*}=$store/${spec#*=}"
        parts="$parts $pkg:${spec%%=*}=$store/${spec#*=}"
    done < "$store/parts.txt"
    assemble "$dir/beam_nifs.com" "$dir/beam.com" "$(files "$store/nifs" "$store/licenses")" $specs
    # The same program from the segments that the FIFO beam.com streams
    # (assemble.erl --parts): the segments of the list of a set, one after
    # the other, are the bytes of the program of these packages. The
    # program of rusty_csv alone has only its NIF files.
    rm -rf "${dir:?}/program_parts"
    check beam.com 'the program of ex_pdfium\.rusty_csv\.vix has [0-9]* bytes' \
        scripts/assemble.erl -- --parts "$dir/beam.com" "$dir/program_parts" 0123abc beam.com/p/ $parts
    for set in ex_pdfium.rusty_csv.vix rusty_csv; do
        rm -f "$dir/beam_p_$set.com"
        [ -f "$dir/program_parts/beam-p.plus.$set.txt" ] || continue
        sed 's|^beam\.com/p/||' "$dir/program_parts/beam-p.plus.$set.txt" | while read -r f; do
            cat "$dir/program_parts/$f"
        done > "$dir/beam_p_$set.com"
        chmod +x "$dir/beam_p_$set.com"
    done
    if [ -f "$dir/beam_nifs.com" ] && [ -f "$dir/beam_p_ex_pdfium.rusty_csv.vix.com" ] &&
       cmp "$dir/beam_nifs.com" "$dir/beam_p_ex_pdfium.rusty_csv.vix.com"; then
        echo "PASS: the segments of ex_pdfium.rusty_csv.vix are beam_nifs.com"
    else
        echo "FAIL: the segments of ex_pdfium.rusty_csv.vix are not beam_nifs.com"
        fail=1
        failed="$failed
  assemble.erl --parts: the segments are not the bytes of beam_nifs.com"
    fi
    if [ -f "$dir/beam_p_rusty_csv.com" ]; then
        check beam_p_rusty_csv.com 'NIF files   : .*rusty_csv-' --version
        if grep -q -e 'NIF files   : .*vix-' -e 'NIF files   : .*ex_pdfium-' "$tmp"; then
            echo "FAIL: beam_p_rusty_csv.com has the NIF files of more packages"
            fail=1
            failed="$failed
  beam_p_rusty_csv.com: the NIF files of more packages than rusty_csv"
        fi
    fi
    if [ -f "$dir/beam_nifs.com" ]; then
        check beam_nifs.com 'NIF files   : .*ex_pdfium-.* rusty_csv-.* vix-' --version
        check beam_nifs.com '^licenses: pdfium$' -noshell -eval \
            'true = filelib:is_regular("/zip/licenses/pdfium/pdfium.txt"), io:format("licenses: pdfium~n"), halt().'
        # check sets p: the loop has its own name.
        for nif_prog in vix_check rusty_csv_check ex_pdfium_check; do
            rm -rf "${dir:?}/$nif_prog"
            cp -R "tests/programs/$nif_prog" "$dir/$nif_prog"
            # A build compiles the package and its deps: more time.
            limit=600
            net_check beam_nifs.com "wrote .*$nif_prog.com" "$dir/$nif_prog" -o "$dir/$nif_prog.com"
            limit=${LIMIT:-120}
            if [ -f "$dir/$nif_prog.com" ]; then
                check "$nif_prog.com" "^$nif_prog: ok"
            fi
        done
    fi
elif [ -d examples ]; then
    echo "SKIP: store_nif_check.com (no $dir/store_nifs.tar.gz)"
fi

if [ -d examples ]; then
    # W^X: the JIT maps its code two times (executable, and writable),
    # so no page is writable and executable. On Linux, +JMsingle (one
    # mapping) shows that the check sees RWX pages. macOS arm64 uses
    # one MAP_JIT mapping (RWX, with a write permission for each
    # thread). OpenBSD has no memory map for the program to read; its
    # kernel does not allow RWX pages at all.
    check beam.com 'wrote .*jit_maps.b.com' \
        tests/programs/jit_maps.erl -o "$dir/jit_maps.b.com"
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
                    tests/programs/jit_maps.erl --allow-read=/proc \
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
    check beam-emu.com "Emulator    : emu@@OS type     : unix/$os" --version
    if [ -d examples ]; then
        check beam-emu.com 'wrote .*hashsum.emu.com' \
            examples/hashsum.erl -o "$dir/hashsum.emu.com"
        [ -f "$dir/hashsum.emu.com" ] && check hashsum.emu.com "$hashsum" abc
        check beam-emu.com 'wrote .*greeter.emu.com' \
            examples/greeter -o "$dir/greeter.emu.com"
        [ -f "$dir/greeter.emu.com" ] && check greeter.emu.com "$greeter"
        check beam-emu.com 'wrote .*wasm_tests.emu.com' \
            tests/programs/wasm_tests.erl -o "$dir/wasm_tests.emu.com"
        [ -f "$dir/wasm_tests.emu.com" ] && check wasm_tests.emu.com 'wasm_tests: all [0-9]* passed'
        check beam-emu.com 'wrote .*script_check.emu.com' \
            tests/programs/script_check.erl -o "$dir/script_check.emu.com"
        if [ -f "$dir/script_check.emu.com" ]; then
            check script_check.emu.com 'argc 2@@arg b c$@@arg 日本$' args "b c" 日本
            check_status 127 script_check.emu.com 'exception error: {boom,42}' raise
            check_status 3 script_check.emu.com 'halting 3' halt 3
            check script_check.emu.com '^line 100000$@@^last line$' big
        fi
        check beam-emu.com 'wrote .*crypto_check.emu.com' \
            tests/programs/crypto_check -o "$dir/crypto_check.emu.com"
        [ -f "$dir/crypto_check.emu.com" ] && check crypto_check.emu.com "$crypto_check"
        # The sandbox with the interpreter (the sandbox checks above use
        # beam.com, the JIT, for which the launcher adds "prot_exec").
        check beam-emu.com 'wrote .*sandbox_net.emu.com' \
            tests/programs/sandbox_check.erl -N -o "$dir/sandbox_net.emu.com"
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
        tests/programs/sqlite_check.erl -o "$dir/sqlite_check.b.com"
    if [ -f "$dir/sqlite_check.b.com" ]; then
        check sqlite_check.b.com "$sqlite:memory:"
        rm -f "$dir/test.db"
        check sqlite_check.b.com "${sqlite}$dir/test.db" "$dir/test.db"
    fi
    if [ -f "$dir/beam-emu.com" ]; then
        check beam-emu.com 'wrote .*sqlite_check.emu.com' \
            tests/programs/sqlite_check.erl -o "$dir/sqlite_check.emu.com"
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
        sample_named "$first" 400 > "$tmp.sample"
        head -80 "$tmp.sample"
        # A child of fork() in a fork handler of libSystem: C32 of docs/UPSTREAM.md.
        if grep -q '_atfork_child' "$tmp.sample"; then
            echo "--- the child of fork() hangs in a fork handler of libSystem (docs/UPSTREAM.md, C32)"
        fi
        rm -f "$tmp.sample"
    fi
fi
if [ $fail -ne 0 ]; then
    echo "==> Failed checks:$failed"
else
    echo "==> All checks passed"
fi
exit $fail
