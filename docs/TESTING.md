# Testing

BEAM.com has unit tests, behavior tests on each system, and benchmarks.
Each feature has tests of its behavior, also for errors and limits, not
only for the normal case.

## 1. Unit tests (Erlang, with coverage)

`tests/unit/*_tests.erl` are EUnit tests for the Erlang code of
`apps/beam_com` (the commands, the builder, the Hex client, the Elixir
and `--target wasm32` parts, and the zip writer), `apps/beam_com_script`,
and `wasm_host_sqlite` (the Ecto SQLite shim of the Workers).

```sh
./build.sh unit            # after the make step; needs no beam.com
```

`tests/unit/run.escript` compiles the modules with `-DTEST` (which
exports the internal functions) under `cover`, runs the tests, and
prints the line coverage of each module. The HTML report is in
`build/unit/cover/`. The step fails when a test fails.

The oracle of the zip tests is independent code: the `zip` module of
stdlib and Info-ZIP `unzip` must read every file that the writer makes.
The builder tests use the real OTP applications (linked into a temporary
`lib/`), and run a full build with a fake executable.

Some code runs only in a real `beam.com`, and the behavior tests cover
it: `beam_com:main/0` and `beam_com_script` halt the node.

## 2. Behavior tests in beam.com

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

## 3. Systems

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

## 4. Benchmarks

`tests/bench/run.sh` (and `run.ps1`) measure the size, the start time and
the speed of typical work for each variant. CI runs them after the tests
on each system. See [`BENCHMARKS.md`](BENCHMARKS.md).
