# Testing

BEAM.com is tested in three layers. Each feature has tests of its
behavior, also for errors and limits, not only for the normal case.

## 1. Unit tests (Erlang, with coverage)

`tests/unit/*_tests.erl` are EUnit tests for the Erlang code of
`apps/beam_com` (the commands, the builder and the zip writer).

```sh
./build.sh unit            # after the make step; needs no beam.com
```

`tests/unit/run.escript` compiles the modules with `-DTEST` (which
exports the internal functions) under `cover`, runs the tests, and
prints the line coverage of each module. The HTML report is in
`build/unit/cover/`. The step fails when a test fails.

| Module | Coverage | Not covered |
|---|---|---|
| `beam_com_zip` | 100% | |
| `beam_com_build` | 98.8% | the `-beam_com_exe` argument (only in a real `beam.com`), and a `systools` result that `silent` does not give |
| `beam_com` | 85.7% | `main/0`, which halts the node (tested by `tests/run.sh`), and the fallback when the `.app` file is missing |
| `beam_com_script` | 0% | it halts the node (tested by `tests/programs/script_check.erl`) |

The oracle of the zip tests is independent code: the `zip` module of
stdlib and Info-ZIP `unzip` must read every file that the writer makes.
The builder tests use the real OTP applications (linked into a temporary
`lib/`), and run a full build with a fake executable.

## 2. Behavior tests in beam.com

These programs are built with `beam.com INPUT -o OUTPUT` and run in `beam.com`
itself, on each platform (the static NIFs exist only there):

| Program | What it checks |
|---|---|
| `tests/programs/wasm_tests.erl` | every value type at its limits (i32, i64, f32, f64, NaN and infinity), wrong arguments, all trap kinds and the recovery after a trap, stack exhaustion, memory bounds and growth, 50 processes calling one instance, resource lifetime, missing imports, WASI arguments, environment and exit codes |
| `tests/programs/script_check.erl` | one-file programs: the arguments (spaces, UTF-8, text that looks like flags), exit codes (return, exception, throw, exit, `halt(N)`), 100000 lines written before the exit, `ERL_FLAGS` |
| `examples/*` | the examples, built with rebar3 and with `beam.com INPUT -o OUTPUT`: releases, crypto (exact hash values), TLS (a local handshake and a verified HTTPS request), port programs, SQLite, WebAssembly and a Go WASI program |

`tests/run.sh` (Unix) and `tests/run.ps1` (Windows) run them and check
the output and the exit status of each one, with a time limit. They also
check the errors of `beam.com INPUT -o OUTPUT` (exit status 1 and the message).

```sh
tests/run.sh DIR           # DIR has beam.com (and the CI artifacts)
```

## 3. Platforms

CI runs layer 2 on Linux (x86_64, aarch64), macOS (arm64, x86_64),
Windows, FreeBSD, NetBSD and OpenBSD 7.3, and layer 1 in the build job.

Without CI, two platforms can be tested on a Linux x86_64 machine:

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
on each platform. See [`BENCHMARKS.md`](BENCHMARKS.md).
