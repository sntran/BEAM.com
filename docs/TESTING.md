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

`build.sh` builds beam.com: it compiles each directory of `src/` as its
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
- StreamData properties, in the test file of their module. A property
  uses an independent oracle where one exists: the `Version` module of
  Elixir for the versions and the requirements of Hex, `io_lib`,
  `file:consult/1` and `erl_tar` for `metadata.config` and the
  tarballs, the `zip` module of stdlib for the zip writer, and the `json`
  module of OTP for the values that go to the WebAssembly host.
- `examples/studio/test`: the tests of the import rewrite of the studio.
  `./build.sh unit` runs them after the tests of the root project.

`tests/support/` has the code that the tests share, for example
`BeamCom.HexFixture`, a local Hex server. A test that needs a directory
with no project (the commands of beam.com look for a project in the
current directory) uses the `tmp_dir` tag and runs in that directory.
Such a module is not async.

```sh
mix deps.get
mix test                   # all the tests
mix test --cover           # with the coverage of each module, in cover/
./build.sh unit            # after the make and elixir steps; needs no beam.com
```

The test environment compiles the Erlang code with `-DTEST`, which
exports the internal functions. The tests need an OTP with `tools` (for
`--cover`), `parsetools` and `asn1`: the zip of beam.com does not have
`tools`. `./build.sh unit` uses the OTP build tree and the Elixir of the
build, and builds `tools` when it is not there. It also checks the
warnings and the format.

`mix test --cover` fails when the coverage of the code (without the test
modules) is less than the threshold in `mix.exs`.

The oracle of the zip tests is independent code: the `zip` module of
stdlib and Info-ZIP `unzip` must read every file that the writer makes.
The builder tests use the real OTP applications (linked into a temporary
`lib/`), and run a full build with a fake executable.

Some code runs only in a real `beam.com`, and the behavior tests cover
it: `beam_com:main/0` and `beam_com_script` halt the node.

## 2. Models

TLC checks the models of four protocols. Each model has an invariant
that a known fault breaks, so a check that passes means something.

| Model | What it checks |
|---|---|
| `specs/KvBlocks.tla` | The blocks of a value in Workers KV: a reader gets a whole version or no version, and the old version stays until the new one is complete. |
| `specs/GreenThreads.tla` | The green threads of the wasm runtime (`jspi_lib.js`, `jspi_pthread.c`): one thread runs at a time, no wake is lost, and no thread wakes before it waits. |
| `specs/Admission.tla` (with `MC_Admission.tla`) | The admission of visitors: at most `Max` run, at most one for each address, and the queue keeps its order. |
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

```sh
tests/run.sh DIR           # DIR has beam.com (and the CI artifacts)
```

| Program | What it checks |
|---|---|
| `tests/programs/wasm_tests.erl` | WebAssembly: every value type at its limits, wrong arguments, all trap kinds and the recovery after a trap, stack exhaustion, memory bounds and growth, 50 processes that call one instance, missing imports, and WASI arguments, environment and exit codes. |
| `tests/programs/wasm_check.erl`, `tests/programs/hello_go` | A WebAssembly module, and a WASI program in Go (`GOOS=wasip1`). |
| `tests/programs/script_check.erl` | One-file programs: the arguments (spaces, UTF-8, text that looks like flags), exit codes (return, exception, throw, exit, `halt(N)`), 100000 lines written before the exit, `ERL_FLAGS`. |
| `tests/programs/sandbox_check.erl` | The `--allow-*` flags: what each one allows and refuses. |
| `tests/programs/jit_maps.erl` | No page of the JIT code is writable and executable. |
| `tests/programs/elixir_check.ex` | A one-file Elixir program. |
| `tests/programs/sqlite_check.erl` | SQLite: a database in memory and in a file. |
| `tests/programs/crypto_check`, `tls_check` | Crypto (exact hash values), port programs, a local TLS 1.3 handshake, and a verified HTTPS request. Also as rebar3 releases in the zip. |
| `tests/programs/calc` | A scanner, a parser and an ASN.1 module. |
| `examples/*` | The examples: a release in the zip, Hex packages, a Mix project, a command line program, distributed Erlang and a remote shell, and `--target wasm32` (the build and its files; the Workers do not run in CI). |

`tests/run.sh` also runs the tools of Elixir (`mix.com`, `iex.com`,
`elixir.com`, `elixirc.com`, `escript`), a new Phoenix app with SQLite
and `phx.gen.auth` (Linux, with the network), the file watchers, and a
check of WSL2 in a user namespace of Linux.

## 4. Systems

CI runs the behavior tests on Linux (x86_64, aarch64), macOS (arm64,
x86_64), Windows, FreeBSD, NetBSD and OpenBSD 7.3, and the unit tests in
the build job.

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

## 5. Benchmarks

`tests/bench/run.sh` (and `run.ps1`) measure the size, the start time and
the speed of typical work for each variant. CI runs them after the tests
on each system. See [`BENCHMARKS.md`](BENCHMARKS.md).
