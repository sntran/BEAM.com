# Benchmarks

The benchmarks show what a feature costs and what it gives: file size,
start time, and the speed of typical work. They help to decide if a
feature is worth its cost.

## How to run them

```sh
tests/bench/run.sh DIR          # Unix; DIR has beam-emu.com and beam.com
tests/bench/run.ps1 -Dir DIR    # Windows
```

The script builds [`tests/bench/bench.erl`](../tests/bench/bench.erl)
with each variant (`beam-emu.com bench.erl -o OUTPUT` and
`beam.com bench.erl -o OUTPUT`), runs it, and prints one Markdown table. CI runs it on each platform after the tests
for a push to `main`, and puts the table in the summary of the run. A pull
request has the performance gate (below) in place of the tables.

| Row | What it measures |
|---|---|
| file size | the size of the variant |
| size of a program | a program that `beam.com bench.erl -o OUTPUT` makes (bench.erl with its applications) |
| start: `--version` | `beam.com --version`: start, boot, one command, stop (the median of 10 runs) |
| start: a program | a built program that does nothing (the median of 10 runs) |
| fib | function calls: `fib(32)` |
| lists | `lists:sort/1`, `map/2` and `foldl/3` on 1000000 numbers |
| maps | 200000 map inserts and lookups |
| ets | 200000 ETS inserts and lookups |
| binary | build a 5 MB binary and match each byte |
| messages | 200000 messages there and back between two processes |
| crypto | SHA-256 of 64 MB (in the crypto NIF) |
| sqlite | 20000 inserts in one transaction and a query (in SQLite) |
| wasm_calls | 100000 calls from Erlang into WebAssembly |
| wasm_loop | a loop in WebAssembly (the WAMR interpreter) |

Each workload runs 3 times, and the best time is shown. The times are
for comparing variants on the same machine. CI machines are shared, so
expect some noise; a difference of less than about 10% does not tell
much.

## The performance gate

A pull request must not make `beam.com` slower. CI runs
[`tests/bench/gate.sh`](../tests/bench/gate.sh) on Linux x86_64 for
each pull request:

```sh
tests/bench/gate.sh NEW BASE [CASE...]
```

The base is the `edge` build of `main`, with its SHA-256 checked. Shared
machines are noisy, so the gate compares the two files on the same
machine at the same time:

1. It builds `bench.erl` with each file.
2. It runs the two programs in turns, 5 times (`ROUNDS`). The first
   program changes each round.
3. It keeps the best time of each case for each file. The start time of
   a program is also a case.

The gate fails when one of these is true:

| Limit | Default |
|---|---|
| A case is slower by more than `LIMIT` percent, and also by more than `SLACK` ms. | 20%, 5 ms |
| The geometric mean of the ratios is above 1 by more than `MEAN` percent. | 10% |
| The file is larger by more than `SIZE` percent. | 10% |

The table of the gate goes to the summary of the run. With 5 rounds on a
machine with 4 CPUs, a run of one file against itself gave ratios from
0.94 to 1.09. With 2 rounds, the ratios went from 0.72 to 1.40, so do not
use fewer rounds for the gate.

CI also runs the gate with `beam-emu.com` as the new file and `beam.com`
as the base (the cases `fib` and `binary`). That run must fail, because
`fib` is about 2 times slower in the interpreter. This check makes sure
that the gate itself stays live.

A change that is slower on purpose (for example, a new safety check)
must say so in its pull request, and the owner decides.

## JIT (BeamAsm) against the interpreter

The tables below were measured when `beam.com` was the interpreter and
`beam-jit.com` the JIT. Now `beam.com` is the JIT and `beam-emu.com` the
interpreter; the files are the same.

Local measurement, Linux x86_64 (4 CPUs), two runs; `beam.com` is an
x86_64-only interpreter build here and `beam-jit.com` the fat JIT, so
the file sizes are not comparable in this table (CI compares two fat
files):

| | beam.com | beam-jit.com | JIT / interpreter |
|---|---:|---:|---:|
| start: `version` (ms) | 162-164 | 237-249 | +45% (about +75 ms) |
| start: a program (ms) | 130-134 | 186-199 | +45% (about +60 ms) |
| fib (ms) | 49 | 25-27 | 0.5 |
| lists (ms) | 339-361 | 265-286 | 0.8 |
| maps (ms) | 127-130 | 107-116 | 0.9 |
| ets (ms) | 120-127 | 103-111 | 0.9 |
| binary (ms) | 327-334 | 223-226 | 0.7 |
| messages (ms) | 135-142 | 132-143 | 1.0 |
| crypto (ms) | 237-243 | 246-254 | 1.0 |
| sqlite (ms) | 185-216 | 186-196 | 1.0 |
| wasm_calls (ms) | 492-531 | 524-537 | 1.0 |
| wasm_loop (ms) | 66-69 | 64-65 | 1.0 |

What this says:

- **Erlang code** is faster with the JIT: function calls 2 times,
  binaries 1.5 times, lists, maps and ETS 1.1 to 1.3 times.
- **Code in C** (crypto, SQLite, WebAssembly, the scheduler for
  messages) does not change.
- **The start** is about 60 to 75 ms slower: the JIT compiles each module
  to machine code when it loads it, and a program loads many modules at
  the start.
- **The size** is 2.8 MB more for the fat file with both backends
  (37.2 MB and 40.0 MB in CI), and the same for each program that
  a build (`-o`) makes from it.

So the JIT helps long-running programs and servers that run Erlang
code, and it costs short command-line programs, which mostly start and
stop. The measurements of all platforms (from CI) are below.

## All platforms (CI)

From the CI run of the fat JIT: two fat files (x86_64 and aarch64 in
each), the same code with and without `JIT=1`. Each cell is
interpreter → JIT, in milliseconds (less is better).

| Platform | start: `--version` | start: a program | fib | lists | binary | maps | ets | messages |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Linux x86_64 | 142 → 222 | 110 → 179 | 70 → 30 | 249 → 116 | 249 → 133 | 83 → 68 | 70 → 64 | 111 → 117 |
| Linux aarch64 | 110 → 175 | 87 → 143 | 139 → 12 | 411 → 104 | 290 → 91 | 102 → 81 | 111 → 90 | 156 → 154 |
| macOS arm64 | 138 → 224 | 104 → 141 | 217 → 19 | 823 → 139 | 469 → 111 | 102 → 55 | 132 → 89 | 141 → 161 |
| macOS x86_64 | 297 → 485 | 230 → 393 | 133 → 59 | 802 → 333 | 671 → 310 | 219 → 191 | 223 → 238 | 237 → 308 |
| Windows x86_64 | 239 → 318 | 238 → 317 | 68 → 27 | 258 → 167 | 276 → 155 | 101 → 82 | 104 → 103 | 98 → 102 |
| FreeBSD x86_64 | 147 → 232 | 120 → 187 | 72 → 31 | 267 → 151 | 261 → 152 | 86 → 71 | 75 → 70 | 114 → 118 |
| NetBSD x86_64 | 151 → 221 (1) | 130 → 191 (1) | 70 → 32 | 303 → 215 | 285 → 168 | 101 → 81 | 94 → 100 | 114 → 123 |
| OpenBSD 7.3 x86_64 | 256 → 447 (1) | 222 → 384 (1) | 41 → 20 | 313 → 259 | 270 → 214 | 83 → 74 | 84 → 81 | 98 → 106 |

| Windows arm64, native ARM64 (2) | 189 → 250 | 174 → 237 | 151 → 13 | 406 → 78 | 273 → 95 | 76 → 55 | 92 → 68 | 144 → 151 |
| Windows arm64, x64 emulation (2) | 428 → 766 | 380 → 698 | 187 → 158 | 664 → 481 | 847 → 483 | 204 → 187 | 234 → 226 | 410 → 402 |

(1) From the next CI run: in the first run, the benchmark did not find
the APE loader from its relative path (fixed in `bench.erl`).
(2) From a later CI run (run 737, 19 November 2026). See "Windows on
ARM64" below.

The code in C does not change with the JIT (crypto, SQLite, WebAssembly;
the full tables are in the summary of each CI run): the differences are
in the noise, from −10% to +10%, with one outlier (SQLite on macOS
arm64, 94 → 128 ms).

What this says, for all platforms:

- **On aarch64 the JIT helps most**: function calls 11 to 12 times
  faster, lists 4 to 6 times, binaries 3 to 4 times. The aarch64
  interpreter is slow (fib is 2 to 3 times slower than on x86_64), and
  the JIT makes aarch64 as fast as x86_64 or faster.
- **On x86_64** the JIT makes function calls 2 to 2.5 times faster,
  lists and binaries 1.2 to 2.4 times, maps 1.1 to 1.25 times; ETS
  does not change much.
- **Messages** do not become faster (the time is in the scheduler).
- **The start** is 40 to 90 ms slower on every platform (+35% to
  +65%; macOS x86_64 and OpenBSD about +190 ms, on slow machines), because the JIT compiles the
  modules that the boot loads.

So the JIT is worth it for long-running Erlang code, most of all on
aarch64 (Apple Silicon, ARM servers). It costs 2.8 MB and the slower
start, which matters for small command-line programs.

## Windows on ARM64: native code against the x64 emulation

On Windows 11 on ARM64, `beam.com` runs its aarch64 half as native code
(see "Windows on ARM64" in [`PLATFORMS.md`](PLATFORMS.md)).
`BEAM_COM_NATIVE=0` keeps the x86_64 half, which Windows runs under its
x64 emulation, as the versions before did. `tests/bench/run.ps1` measures
each variant both ways on the same machine. The numbers come from CI run
737 (19 November 2026), on the runner `windows-11-arm` (Cobalt 100,
4 cores), in milliseconds (less is better):

| | `beam-emu.com` native | `beam-emu.com` emulation | `beam.com` native | `beam.com` emulation | `beam.com`: emulation / native |
|---|---:|---:|---:|---:|---:|
| start: `--version` | 189 | 428 | 250 | 766 | 3.1 |
| start: a program | 174 | 380 | 237 | 698 | 2.9 |
| fib | 151 | 187 | 13 | 158 | 12 |
| lists | 406 | 664 | 78 | 481 | 6.2 |
| maps | 76 | 204 | 55 | 187 | 3.4 |
| ets | 92 | 234 | 68 | 226 | 3.3 |
| binary | 273 | 847 | 95 | 483 | 5.1 |
| messages | 144 | 410 | 151 | 402 | 2.7 |
| crypto | 144 | 815 | 143 | 817 | 5.7 |
| sqlite | 123 | 540 | 128 | 351 | 2.7 |
| wasm_calls | 324 | 737 | 337 | 684 | 2.0 |
| wasm_loop | 99 | 486 | 99 | 488 | 4.9 |

The files are the same in both columns: 38.9 MB for `beam.com`, and
29.4 MB for a program that it builds.

What this says:

- **Each workload is faster natively**, 2 to 12 times with the JIT.
  Erlang code gains the most (fib 12 times, lists 6 times, binary 5
  times), because the emulation translates the x86_64 code of the JIT
  again. Code in C gains 2.7 to 5.7 times (crypto, SQLite, WebAssembly).
- **The start is about 3 times faster** natively (250 ms against
  766 ms), although a native start has two processes: the x86_64 half
  starts under the emulation, and it starts the loader of the aarch64
  half.
- **The interpreter gains less** (fib 1.2 times, lists 1.6 times), but
  the code in C gains as much as with the JIT.

In the same run, the runner `windows-latest` (x86_64) gave 305 ms for
`--version`, 30 ms for fib, 119 ms for lists, and 254 ms for crypto with
`beam.com`. That is another machine, so compare these numbers with care.

## Stored `kernel` and `stdlib` (a faster start)

The zip of `beam.com` stores the code of `kernel` and `stdlib` without
compression, and all other files compressed. The boot loads these
modules first, and a stored entry is read without inflating it.
Local measurement, Linux x86_64 (x86_64-only interpreter build), the
median of 11 runs of `beam.com --version`, two runs:

| | all compressed | `kernel` and `stdlib` stored | difference |
|---|---:|---:|---:|
| file size (MB) | 27.2 | 29.1 | +1.9 MB |
| start: `version` (ms) | 193-202 | 143-146 | about −50 ms (−27%) |

The programs that `beam.com INPUT -o OUTPUT` makes keep these entries
stored, so they start faster too. A zip with no compression at all is about 21 MB
larger, so only these two applications are stored.

## What each feature costs

The size that each part adds to `beam.com` (fat, both CPUs), and to the
programs that it builds. The programs get only what they use, except the
parts in the emulator (C code), which are in every program.

| Part | `beam.com` | A program | Where it is |
|---|---:|---:|---|
| JIT (BeamAsm) | +2.8 MB | +2.8 MB | emulator; start 40 to 90 ms slower |
| SQLite (esqlite) | +1.8 MB | +1.8 MB | emulator (`SQLITE=0` leaves it out) |
| WebAssembly (WAMR) | +0.6 MB | +0.6 MB | emulator (`WASM=0` leaves it out) |
| `kernel` and `stdlib` stored | +1.9 MB | +1.8 MB | zip; start about 50 ms faster |
| Code without docs and debug information | | −7.7 MB | zip of the program (as `mix release` strips it); start the same |
| Elixir (`elixir`, `eex`, `ex_unit`, `iex`, `logger`, `mix`, with docs) | +2.8 MB | 0 for Erlang programs | zip (`ELIXIR=0` leaves it out) |
| The NIF of `rusty_csv` (`EXTRA_NIFS`) | +1.3 MB | +1.3 MB | emulator (custom builds) |
| The NIF of `vix`, with libvips | +13 MB | +13 MB | emulator (custom builds) |
| The parts `icc`, `gif`, `avif` and `svg` of `vix` (`VIX_PARTS`) | under 1 MB, under 1 MB, +12 MB, +5.5 MB | the same | emulator (custom builds) |
| The NIF of `ex_pdfium`, with PDFium | +18.7 MB | +18.7 MB | emulator (custom builds) |
| An Elixir program (`elixir` and `compiler`) | | +1.9 MB, start about 40 ms slower | zip of the program |

The last two rows were measured locally (Linux x86_64, the fat JIT): a
one-file program that prints one line, in Erlang (27.2 MB, 182 ms) and
in Elixir (29.1 MB, 223 ms), the median of 7 starts. Before the code of
the programs was stripped, the same programs were 34.9 MB (188 ms) and
39.0 MB (225 ms).

The rows of the NIFs compare the builds of `rust.yml`, `vix.yml` and
`pdfium.yml` (`SQLITE=0 WASM=0`, with Elixir). With `ex_pdfium`, that
`beam.com` is 68.3 MB, and `ex_pdfium_check.com` is 48.6 MB.

## ex_pdfium (PDFium)

[`tests/programs/ex_pdfium_check`](../tests/programs/ex_pdfium_check)
with the argument `bench 5`: the median of 5 runs, in milliseconds.
[`pdfium.yml`](../.github/workflows/pdfium.yml) runs it on each system
with `beam.com` (`EXTRA_NIFS=ex_pdfium`, PDFium of `scripts/pdfium.sh`).
It also runs it on Linux with the precompiled NIF of ex_pdfium 0.6.0 (its
GitHub release, with the dynamic PDFium of bblanchon/pdfium-binaries),
on Erlang/OTP 29.1.1 and Elixir 1.20.4. There is no precompiled NIF for
Windows. The rows come from two runs of 2 November 2026 (run 10 and run
11), on shared machines.

| NIF, system | make 20 pages | render a page, 150 dpi | render a page, 300 dpi | text of 20 pages |
|---|---:|---:|---:|---:|
| beam.com, Linux x86_64 | 25.1 | 7.7 | 30.5 | 0.7 |
| precompiled, Linux x86_64 | 40.9 | 10.2 | 46.5 | 1.0 |
| beam.com, Linux aarch64 | 29.7 | 7.1 | 28.6 | 1.1 |
| precompiled, Linux aarch64 | 32.4 | 7.0 | 28.9 | 0.9 |
| beam.com, macOS arm64 (3 schedulers) | 41.6 | 16.1 | 40.3 | 8.1 |
| beam.com, macOS x86_64 | 48.9 | 14.2 | 48.1 | 1.5 |
| beam.com, Windows x86_64 | 21.7 | 3.1 | 13.1 | 0.6 |

On Linux aarch64, the times of the two NIFs are near. On Linux x86_64,
`beam.com` was faster in these runs, but the two jobs ran on different
machines, so this does not show that the NIF of `beam.com` is faster.
On macOS arm64 (a virtual Apple M1 with 3 CPUs), the time of the text
changes from process to process. The 8.1 ms of the table came from one
process. A later check started the same program 5 times, with 25 runs in
each: the text of 20 pages took 10.0, 1.5, 1.5, 1.1 and 0.9 ms. The
render times of the slow process were normal. In the same check, Linux
aarch64 gave 1.1 ms in each process, and macOS x86_64 gave 1.7 to 2.1 ms.
So the usual time on macOS arm64 is near that of the other systems. We
do not know why one process in some runs is slow.

## The WebAssembly runtime

For the speed and the cold start of the edge part of `app.com`, see "Measured" in
[`WORKERS.md`](WORKERS.md), and the full tables in
[`history/WASM-LOG.md`](history/WASM-LOG.md).
