# Testing

BEAM.com has unit tests, behavior tests on each system, and benchmarks.
Each feature has tests of its behavior, also for errors and limits, not
only for the normal case.

## 1. Unit tests (one Mix project, with coverage)

The repository is one Mix project (`mix.exs`):

| Directory | Contents |
|---|---|
| `src/APP/` | The Erlang code of each OTP application: `beam_com`, `beam_com_script`, `wasm` and `wasm_host`. |
| `c_src/` | The C code: `cosmo/` (the native executable), `erts_wasm/` (the WebAssembly runtime) and `wasm/` (the NIF of WAMR). |
| `priv/wasm_host/` | The JavaScript of the hosts of the WebAssembly runtime. |
| `lib/` | The Elixir code: the models of the protocols and the Mix tasks. |
| `tests/` | The tests, with ExUnit. |

The Makefile builds beam.com: it compiles each directory of `src/` as its
own application. Mix compiles all of `src/` as one application, only for
the tests.

`mix test` runs these tests:

- The ExUnit tests of the Erlang code. Their paths follow the paths of
  the code: `tests/APP/MODULE_test.exs` tests `src/APP/MODULE.erl`, with
  the module `ModuleTest` (for example, `tests/beam_com/beam_com_zip_test.exs`
  and `BeamComZipTest`). They cover `src/beam_com` (the commands, the
  builder, the Hex client, the Elixir and `--target wasm32` parts, and the
  zip writer), `src/beam_com_script`, and `src/wasm_host` (the Ecto SQLite
  shim of the Workers).
- `tests/host_test.exs`: the tests of the JavaScript of the hosts
  (`tests/host/*.test.mjs`) with `node --test`. They need Node.js 20.6 or
  later. Without `node`, ExUnit skips them (the tag `node`).
- `tests/beam_com/beam_com_git_ssh_test.exs`: a test of the git client
  with the `git-upload-pack` program of git. Without `git`, ExUnit skips
  it (the tag `git`).
- The tests of the Mix release in `tests/beam_com/beam_com_mix_test.exs`
  start a child `beam.com`. They need a test VM of `beam.com` (the init
  argument `beam_com_exe`, as in `make unit`). Without it, ExUnit skips
  them (the tag `beam_com_exe`).
- StreamData properties, in the test file of their module. A property
  uses an independent oracle where one exists: the `Version` module of
  Elixir for the versions and the requirements of Hex, `io_lib`,
  `file:consult/1` and `erl_tar` for `metadata.config` and the
  tarballs, the `zip` module of stdlib for the zip writer, and the `json`
  module of OTP for the values that go to the WebAssembly host.
- `tests/wasm_diff_test.exs`: the differential test. Each program of
  `tests/wasm_diff/` runs in the native OTP and in the WebAssembly
  runtime of `--target wasm32`, and the two outputs must be the same.
  See "The differential test" below.
- `tests/elixir_patches_test.exs`: the tests of the patches of Elixir
  (`patches/elixir/`), with the `elixir` of the PATH. The test of the
  build lock of Mix runs in a user and network namespace
  (`unshare -rn`). Without it, ExUnit skips the test (the tag `netns`).
  CI sets `BEAM_COM_NETNS=1`, so there the test must run.
- `tests/beam_com/beam_com_git_ssh_test.exs`: the tests of Git over SSH,
  with an SSH daemon of OTP and a test agent on the loopback address. The
  tests of the program `ssh_agent_bridge` (the tag `agent_bridge`) need
  the helper in the `beam.com` of the tests, or `BEAM_COM_AGENT_BRIDGE`
  (a build of `c_src/cosmo/beam_com_agent.c` with
  `-DBEAM_COM_AGENT_MAIN`). Without them, ExUnit skips these tests.
- `tests/beam_com/beam_com_git_test.exs`: the tests of the SHA-1 check
  of the git client use small shell scripts as false helpers (an attack,
  a wrong digest, a bad answer, an exit, no answer). The tests of the
  program `git_sha1dc` (the tag `sha1dc`) need the helper in the
  `beam.com` of the tests, or `BEAM_COM_SHA1DC` (a build of
  `c_src/cosmo/beam_com_sha1dc.c` with `-DBEAM_COM_SHA1DC_MAIN`).
  Without them, ExUnit skips these tests.
- `tests/check_format_test.exs`: the tests of the file format checks.
  See "File formats" below.
- `tests/errno_test.exs`: the errors of the VM have the names of the
  BEAM, such as `eloop` and `ealready` (C35 in
  [`UPSTREAM.md`](UPSTREAM.md)). In CI, the tests run in `beam.com`, so
  the test checks the patch of `erl_errno_str.c`.
- `examples/studio/test`: the tests of the import rewrite of the studio.
  `make unit` runs them after the tests of the root project.

`tests/support/` has the code that the tests share, for example
`BeamCom.HexFixture`, a local Hex server. A test that needs a directory
with no project (the commands of beam.com look for a project in the
current directory) uses the `tmp_dir` tag and runs in that directory.
Such a module is not async.

```sh
mix deps.get
mix test                   # all the tests
mix test --cover           # with the coverage of each module, in cover/
make unit                  # with the beam.com of the build
beam.com mix test --cover  # the same, with a beam.com of your own
```

The test environment compiles the Erlang code with `-DTEST`, which
exports the internal functions. The tests need an OTP with `tools` (for
`--cover`), `parsetools` and `asn1`: beam.com has them. `make unit` runs
the tests with the `beam.com` of the build (`beam.com mix`), after the
`bundle` step. It also checks the warnings and the format. The tests also
pass with a usual installation of Erlang and Elixir.

Run them as `beam.com mix`, not with a link named `mix`: some tests
expect the messages of a file named `beam.com`.

`mix test --cover` fails when the coverage of the code (without the test
modules) is less than the threshold in `mix.exs`.

The oracle of the zip tests is independent code: the `zip` module of
stdlib and Info-ZIP `unzip` must read every file that the writer makes.
The builder tests use the real OTP applications (linked into a temporary
`lib/`), and run a full build with a fake executable.

`beam_com:main/0` and the run of a `beam_com_script` program halt the
node. Their tests run them in a peer node (the `peer` module of OTP),
with `BeamCom.PeerNode` of `tests/support/`. The test node gets the exit
status and the output of the peer, also its standard error. The code of
a peer is not cover-compiled, so these tests add nothing to the
coverage.

### The differential test

The programs of `tests/wasm_diff/` print the results of integers and
floats, the external term format, hashes, Unicode, regular expressions,
JSON, processes, timers, ETS, files, the waits of libc (`fsync()` and
`select()`), and crypto. They print no pid, no time, and no path. The
test runs each program three times:

1. In the native OTP of the test, with `LC_ALL=C.UTF-8`.
2. In the Worker build of `beam.wasm`, in Node.js.
3. In the same build, with the timers of a plain Worker: all the timers
   that are due run in one task.

`tests/wasm_diff/run.mjs` runs one program in the runtime. It writes
kernel, stdlib, crypto, and the programs into the memory file system of
the runtime.

The test needs `BEAM_COM_WASM_RUNTIME` (the runtime directory, for
example `build/wasm-runtime`) and Node.js 25 or later (JSPI). The
runtime and the `erl` of the test must come from the same OTP. Without
`BEAM_COM_WASM_RUNTIME`, ExUnit skips the test (the tag `wasm_diff`).
`make unit` sets the variable when the build has the runtime, so
CI runs the test in the build job.

```sh
BEAM_COM_WASM_RUNTIME=build/wasm-runtime mix test tests/wasm_diff_test.exs
```

The test found one permitted difference. Erlang does not specify the
order of the keys of a map with more than 32 keys. With atom keys, this
order in wasm32 is not the order in a 64-bit runtime. The programs print
the sorted keys and the deterministic encoding of such a map.

## 2. Models

TLC checks the models of six protocols. Each model has an invariant
that a known fault breaks, so a check that passes means something.

| Model | What it checks |
|---|---|
| `specs/KvBlocks.tla` | The blocks of a value in Workers KV: a reader gets a whole version or no version, and the old version stays until the new one is complete. |
| `specs/GreenThreads.tla` | The green threads of the wasm runtime (`jspi_lib.js`, `jspi_pthread.c`): one thread runs at a time, no wake is lost, and no thread wakes before it waits. |
| `specs/Admission.tla` (with `MC_Admission.tla`) | The admission of visitors: at most `Max` run, at most one for each address, and the queue keeps its order. |
| `specs/SendWindow.tla` | The send window of a socket (`wasm_tcp`, `tcpSend` of `worker.js`): a send that waits always has a `tcp_sent` to come, the host holds less than the window and one send, and all the sends end. A drain that does not send when the window has room breaks it. |
| `specs/FetchPath.tla` | The HTTP of the VM through `fetch()` (`tcpConnect` of `worker.js`, `wasm_host_fetch`): the route of a connect for each port, rule of `BEAM_FETCH` and trust store, the CA of the server in the VM, and the guard of a snapshot. TLS goes to the server only when the VM trusts its CA, and another protocol than HTTP never goes there. A rule with no port that also gives another port breaks it. |
| `BeamCom.Protocol.Instance` | An Accord contract of one instance: each instance ends, and an instance that ended has no storage. |

```sh
mix beam_com.tlc                      # all models
mix beam_com.tlc --only GreenThreads  # one model of specs/
mix beam_com.tlc --skip-missing       # no error without java or the jar
```

The task runs `mix accord.check` and then TLC for each `specs/*.cfg`.
The part of the file name before the first `.` names the module, so
`MC_Admission.max1.cfg` checks `MC_Admission` with `Max = 1`. A run of
all models takes about one minute.

TLC needs Java 11 or later and `tla2tools.jar`. The task reads the jar
from `TLA2TOOLS_JAR`, then `~/.tla/tla2tools.jar`, then the project
root. CI pins the stable release v1.7.4 (2,274,532 bytes):

```
936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  tla2tools.jar
```

Do not use v1.8.0. It is a nightly build, so its checksum changes.

TLC found a race in the green threads. The plain Worker runs all the
timers that are due in one task. A thread whose timer fired, but which
did not run yet, could then get a wake. That wake went to the next
wait, so the thread ran two times and the run queue became wrong.
`GreenThreads.cfg` sets `Fix = TRUE`. With `Fix = FALSE`, TLC shows the
fault. `tests/host/jspi_lib.test.mjs` checks the same order of events in
Node.

## 3. Behavior tests in beam.com

`tests/run.sh` (Unix) and `tests/run.ps1` (Windows) run `beam.com` and
the programs that it builds, on each system, and check the output and
the exit status of each one, with a time limit. They also check the
errors of `beam.com INPUT -o OUTPUT` (the exit status and the message).
A check that uses the network gets two more tries when it fails, after
10 s and after 30 s, and the log shows each try. Both runners do this
for the HTTPS request of `tls_check` and for Hex and Mix.

```sh
tests/run.sh DIR           # DIR has beam.com (and the CI artifacts)
```

| Program | What it checks |
|---|---|
| `tests/programs/wasm_tests.erl` | WebAssembly: every value type at its limits, wrong arguments, all trap kinds and the recovery after a trap, stack exhaustion, memory bounds and growth, 50 processes that call one instance, missing imports, and WASI arguments, environment and exit codes. |
| `tests/programs/wasm_check.erl`, `tests/programs/hello_go` | A WebAssembly module, and a WASI program in Go (`GOOS=wasip1`). |
| `tests/programs/nif_check` | A NIF library in WebAssembly ([`NIFS.md`](NIFS.md)): an application with a NIF in C and its `.wasm` and AOT files in `priv/`, built with `-o`. The terms, binaries, maps, resources and their destructors, monitors and their down callbacks, `enif_send`, `enif_snprintf`, an I/O queue, exceptions, a trap and the recovery after it, `enif_schedule_nif`, a dirty NIF, an unsupported function, and 32 processes that call the library at the same time. The bad calls that ERTS checks only in a debug build (each one must trap), functions of other types (four results, four parameters, an `i64`), and 20 `load_nif/2` calls that ERTS refuses (on Linux, the address space must not grow by their modules). With the AOT file and with the interpreter. |
| `tests/programs/peer_check.erl` | The `peer` module of OTP: the program starts its own file in erl mode as a node, and controls it through its standard I/O, then through a TCP connection (calls, an error, a reply of 1 MB, a request of 1 MB). Then the exit status of a port program, `os:cmd/1`, a port program that reads its input after 1 s (a full pipe), a node that halts right after a write of 4097 bytes to a port program that reads 300 ms late (the program must get all the bytes), a listen socket that a port program must not get, `os:find_executable/1`, a `#!` script as a port program, and `nouse_stdio`. On Windows also `findstr`, a native program that waits in large reads. On each system, also Windows. |
| `tests/cosmo/agent_check.c` | The pipe of the SSH agent of `c_src/cosmo/beam_com_agent.c` on Windows: the server of the pipe gets a token of the level `SecurityIdentification` only. The build job of CI makes `agent_check.com` for `tests/run.ps1`. |
| `tests/cosmo/pipe_check.c` | The wraps of `c_src/cosmo/beam_com_pipe.c`: on Windows, a write to a non-blocking pipe gives at most its free space, a full pipe takes 1 byte that waits and then gives `EAGAIN`, it is not writable for `select()` and uses no CPU, and 1 MB through the pipe arrives in order. Blocking readers with reads of 1, 4095, 4096 and 65536 bytes get all the data, the reader gets the byte that waits after the close of the write end, and a write after the close of the read end gives `EPIPE`. At the exit of a writer with a byte that waits, a reader that reads 300 ms late gets all of 4097 bytes, a reader that never reads holds the exit for 2 s at most, and with no byte that waits the exit does not wait. `scripts/steps.sh test` runs it on Linux (only the data); the build job of CI makes `pipe_check.com` for `tests/run.ps1`. |
| `tests/cosmo/sha1dc_check.c` | The helper `git_sha1dc` of `c_src/cosmo/beam_com_sha1dc.c` in a child process: many messages in one input (0, 3, 55, 56, 63, 64, 65 and 1,000,000 bytes, and 196,864 bytes in parts) with their SHA-1, the vectors of `tests/programs/sha1dc_vectors.txt` (SHAttered and Shambles) with the mark of an attack and another digest, and the end of the input in a message (status 1). `scripts/steps.sh test` runs it on Linux. |
| `tests/programs/git_sha1dc_check.escript` | The helper `/zip/bin/git_sha1dc` of `beam.com` on each system, also Windows: the vectors have the mark of an attack, good inputs pass, and `beam_com_git:check/2` checks good objects. The option `sha1dc` `none` does not stop the check of `beam.com`. |
| `tests/programs/ssh_agent_check.escript` | Windows only (`tests/run.ps1`): the service `ssh-agent` of Windows OpenSSH with a new key, and the helper program `ssh_agent_bridge` on its named pipe. The keys of the agent, and a signature of the git client (`beam_com_git_ssh:sign/3`). |
| Phoenix on Windows (`tests/run.ps1`) | A new app (`mix phx.new hello --no-ecto`) in one file with `beam.com . -o`: the tailwind and esbuild programs for Windows, the git deps, and `priv` through a link to a directory (C54). Then the file serves the start page and its digested CSS. |
| `tests/programs/script_check.erl` | One-file programs: the arguments (spaces, UTF-8, text that looks like flags), exit codes (return, exception, throw, exit, `halt(N)`), 100000 lines written before the exit, `ERL_FLAGS`. |
| `tests/programs/sandbox_check.erl` | The `--allow-*` flags: what each one allows and refuses. |
| `tests/programs/jit_maps.erl` | No page of the JIT code is writable and executable. |
| `tests/programs/elixir_check.ex` | A one-file Elixir program. |
| `tests/programs/sqlite_check.erl` | SQLite: a database in memory and in a file. |
| `tests/programs/crypto_check`, `tls_check` | Crypto (exact hash values), port programs (`os:cmd/1`, and `inet_gethost` except on Windows), a local TLS 1.3 handshake, and a verified HTTPS request. Also as rebar3 releases in the zip. |
| `tests/programs/runtime_check` | A Mix project with `config/runtime.exs` and no deps: Mix makes its release (`beam_com_mix`), and the file reads the config at its start. On each system, also Windows. |
| `tests/programs/rebuild_check` | Run mode (`beam.com DIR`) with a Mix project and no deps: its alias `assets.deploy` writes a new time to `priv/static/stamp.txt` at each build, as `phx.digest` of Phoenix does. The first run builds, the second run does not build again, and a change of a source file builds again. The copy of the project and the cache (`BEAM_COM_CACHE`) are in `DIR`. Also with `--main`: the build stops, because only Mix can build the project. `tests/run.sh` only. |
| `tests/programs/escript_check` | A command line Mix project (`escript: [main_module: ...]`) with `config/runtime.exs` and no deps: the builder of a plain Mix project makes the file, with a warning that the program does not read `config/runtime.exs`, and the file runs `main/1` with its arguments. With `--tool mix-release`, the build stops and writes no file. On each system, also Windows. |
| `erlang:system_info(system_architecture)` (`tests/run.sh`) | The CPU and the system where the file runs (O28 of [`UPSTREAM.md`](UPSTREAM.md)), not the text of `configure`. |
| `tests/programs/calc` | A scanner, a parser and an ASN.1 module. |
| `examples/*` | The examples: a release in the zip, Hex packages, a Mix project, a command line program, distributed Erlang and a remote shell, and `--target wasm32` (the build and its files; the Workers do not run in CI). |

`tests/run.sh` also runs the tools of Elixir (`mix.com`, `iex.com`,
`elixir.com`, `elixirc.com`, `escript`), and a new Phoenix app with
SQLite and `phx.gen.auth` (Linux, with the network). It then builds the
same app in one file with `beam.com . -o`, with the git client of
`beam.com` for the git deps (`BEAM_COM_GIT=client`), and the file must
serve the start page and its digested CSS. It also runs the file
watchers, a check of WSL2 in a user namespace of Linux, and the
blue-green spike (`examples/bluegreen/check.sh`: a check on Linux, a
probe on the other Unix systems).

`tests/run.ps1` needs PowerShell 7.3 or later. It keeps the tree of the
processes that each check starts, and it stops and shows each one that
still runs after the check. In CI (`GITHUB_ACTIONS`), a check of
`tests/run.ps1` that cannot run, for example with no `pipe_check.com` or
no service `ssh-agent`, is a failed check. The Phoenix checks of both
scripts install the fixed `phx_new` 1.8.16, because a new version can
give other deps.

When a program does not stop in its time limit, or a process stays after
the tests, `tests/run.sh` writes the processes and their stacks: `sample`
on macOS, `procstat -kk` on FreeBSD, and the wait channels on Linux. The
`sample` of macOS gives only addresses for an APE file, so
`tests/symtab.py` adds the name of each function. It reads the symbol
table that cosmocc puts in the zip of the file (`.symtab.arm64` or
`.symtab.amd64`). It also works on a log of CI:

```sh
unzip -p beam.com .symtab.arm64 > symtab    # the beam.com of that run
python3 tests/symtab.py symtab 0x8008485bc  # an address of the log
```

## 4. File formats

`tests/check_format.sh FILE...` checks the formats of an APE file with
tools that are not part of beam.com:

| Format | Tool | What it checks |
|---|---|---|
| ZIP | `unzip -t` | Each entry reads with no error and no warning. |
| PE (Windows) | `pecheck` of cosmocc, `objdump -p` | A PE32+ for x86-64, a console program, NX_COMPAT. No writable code, and each section is inside the file. |
| ELF (x86_64, aarch64) | `assimilate -e` of cosmocc, `readelf` | An executable for the correct machine. No segment is writable and executable, the stack is not executable, each segment is inside the file, and the entry point is in an executable segment. |
| Mach-O (x86_64) | `assimilate -m`, `llvm-objdump --macho` | An executable for x86_64. No segment starts writable and executable, each segment is inside the file, and the start address is in an executable segment. |

macOS on arm64 runs the APE loader, so the file has no Mach-O for arm64.

CI runs the script on each build (`beam.com` and `beam-emu.com`) and on
`hashsum.com`, a program that the build made with `-o`.

```sh
COSMOCC=build/cosmocc tests/check_format.sh build/beam.com
```

`tests/check_format_test.exs` makes four broken copies of a built
`beam.com`: a ZIP with no end record, writable PE code, a writable and
executable ELF segment, and a writable and executable Mach-O segment.
Each copy must fail with the correct message, so a change in the output
of a tool cannot make a check pass with no notice. The test needs
`BEAM_COM_FORMAT_FILE` and `COSMOCC`. `make unit` sets them.

`tests/cosmo/libc_edges.c` calls 20 functions of the libc of
Cosmopolitan with buffers at the edges of a mapping (C33 and C34 in
[`UPSTREAM.md`](UPSTREAM.md)). `make test` builds it with cosmocc two
times. Without the wraps of the emulator, it logs the functions that
fault, so a new cosmocc shows which wraps are no longer necessary. With
the wraps, no function must fault, and the wrapped functions must give
the correct results.

## 5. Systems

CI runs the behavior tests on Linux (x86_64, aarch64), macOS (arm64,
x86_64), Windows, FreeBSD, NetBSD and OpenBSD 7.3, and the unit tests in
their own job, after the build. On NetBSD the tests run through the APE loader, because
its `sh` stops at the NUL bytes of the APE header (C13 of
[`UPSTREAM.md`](UPSTREAM.md)). OpenBSD 7.3 has two jobs at the same time:
one through the APE loader, and one through `sh`.

Without CI, two systems can be tested on a Linux x86_64 machine:

- Linux x86_64: `tests/run.sh DIR`.
- Linux aarch64 (the aarch64 half of the fat file), with qemu:

  ```sh
  printf '#!/bin/sh\nexec qemu-aarch64-static %s "$@"\n' \
      "$PWD/build/cosmocc/bin/ape-aarch64.elf" > qemu-ape.sh
  chmod +x qemu-ape.sh
  RUNNER=$PWD/qemu-ape.sh LIMIT=600 tests/run.sh DIR
  ```

  The helper programs that `beam.com` starts (by running itself again)
  run the x86_64 half.

Wine 9.0 could not run Cosmopolitan programs in a container without a
display (even a "hello" program waits forever), so Windows needs CI or a
Windows machine. macOS and the BSDs also need CI or a real machine.

## 6. Benchmarks

`tests/bench/run.sh` (and `run.ps1`) measure the size, the start time and
the speed of typical work for each variant. CI runs them after the tests
on each system, for a push to `main`. A pull request has the performance
gate in place of the tables. See [`BENCHMARKS.md`](BENCHMARKS.md).
