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
- **The size** is about 5 MB more for the fat file (both backends).

So the JIT helps long-running programs and servers that run Erlang
code, and it costs short command-line programs, which mostly start and
stop. The measurements of all platforms (from CI) are below.

## All platforms (CI)

To be filled from the CI run of the fat JIT.
