# Benchmarks

The benchmarks show what a feature costs and what it gives, so that we
and the users of BEAM.com can decide if it is worth it: file size, start
time, and the speed of typical work.

## How to run them

```sh
tests/bench/run.sh DIR          # Unix; DIR has beam.com and beam-jit.com
tests/bench/run.ps1 -Dir DIR    # Windows
```

The script builds [`tests/bench/bench.erl`](../tests/bench/bench.erl)
with each variant (`beam.com build`, `beam-jit.com build`), runs it, and
prints one Markdown table. CI runs it on each platform after the tests,
and puts the table in the summary of the run.

| Row | What it measures |
|---|---|
| file size | the size of the variant |
| size of a program | a program that `build` makes (bench.erl with its applications) |
| start: `version` | `beam.com version`: start, boot, one command, stop (the median of 10 runs) |
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

## JIT (BeamAsm) against the interpreter

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
  `build` makes from it.

So the JIT helps long-running programs and servers that run Erlang
code, and it costs short command-line programs, which mostly start and
stop. The measurements of all platforms (from CI) are below.

## All platforms (CI)

From the CI run of the fat JIT: two fat files (x86_64 and aarch64 in
each), the same code with and without `JIT=1`. Each cell is
interpreter → JIT, in milliseconds (less is better).

| Platform | start: `version` | start: a program | fib | lists | binary | maps | ets | messages |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Linux x86_64 | 142 → 222 | 110 → 179 | 70 → 30 | 249 → 116 | 249 → 133 | 83 → 68 | 70 → 64 | 111 → 117 |
| Linux aarch64 | 110 → 175 | 87 → 143 | 139 → 12 | 411 → 104 | 290 → 91 | 102 → 81 | 111 → 90 | 156 → 154 |
| macOS arm64 | 138 → 224 | 104 → 141 | 217 → 19 | 823 → 139 | 469 → 111 | 102 → 55 | 132 → 89 | 141 → 161 |
| macOS x86_64 | 297 → 485 | 230 → 393 | 133 → 59 | 802 → 333 | 671 → 310 | 219 → 191 | 223 → 238 | 237 → 308 |
| Windows x86_64 | 239 → 318 | 238 → 317 | 68 → 27 | 258 → 167 | 276 → 155 | 101 → 82 | 104 → 103 | 98 → 102 |
| FreeBSD x86_64 | 147 → 232 | 120 → 187 | 72 → 31 | 267 → 151 | 261 → 152 | 86 → 71 | 75 → 70 | 114 → 118 |
| NetBSD x86_64 | 151 → 221 (1) | 130 → 191 (1) | 70 → 32 | 303 → 215 | 285 → 168 | 101 → 81 | 94 → 100 | 114 → 123 |
| OpenBSD 7.3 x86_64 | 256 → 447 (1) | 222 → 384 (1) | 41 → 20 | 313 → 259 | 270 → 214 | 83 → 74 | 84 → 81 | 98 → 106 |

(1) From the next CI run: in the first run, the benchmark did not find
the APE loader from its relative path (fixed in `bench.erl`).

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
