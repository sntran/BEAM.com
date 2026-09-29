# Crypto, SQLite and WebAssembly

`beam.com` links these libraries into its emulator as static NIFs. A
program gets them with no C compiler and no files on the disk.

## Crypto and TLS

`crypto` and `ssl` work: the `crypto` and `asn1` NIFs are linked into
`beam.com` with a static OpenSSL 4.0.2, and TLS connections verify the
server with the certificates of the OS (on Windows too).

- `public_key:cacerts_get/0` gives the trusted root certificates of the
  OS, on each system. On Windows, BEAM.com exports them from the Windows
  store at start.
- `ssl` makes TLS 1.3 connections, and `:httpc`, Req and Hex use them.
- How it is built: see "Crypto and TLS" in [`INTERNALS.md`](INTERNALS.md).

## SQLite

`beam.com` has SQLite 3.53.4, with the
[esqlite](https://github.com/mmzeeman/esqlite) NIF. SQLite itself is
compiled from its amalgamation with `cosmocc`; esqlite is the small NIF
that gives Erlang code the SQLite API (`esqlite3:open/1`, `exec/2`,
`q/2`, ...). When the code calls `esqlite3`, the builder puts the
`esqlite` application into the program:

```sh
beam.com tests/programs/sqlite_check.erl -o sqlite_check.com
./sqlite_check.com my.db
```

SQLite adds about 1.8 MB (two CPUs) to `beam.com` and to each program
that it makes, also when the program does not use SQLite, because the
NIF is in the emulator. Build with `SQLITE=0` to leave it out.

The NIF of the Elixir package [exqlite](https://hex.pm/packages/exqlite)
(for `ecto_sqlite3`, see "Phoenix from source" in [`ELIXIR.md`](ELIXIR.md)) is also in `beam.com`.
It uses the same SQLite as esqlite: there is one SQLite in the file.
SQLite is compiled with the options of both NIFs (without
`SQLITE_OMIT_AUTOINIT` and `SQLITE_OMIT_PROGRESS_CALLBACK`, which
exqlite cannot use). The NIFs of exqlite and bcrypt_elixir add only
about 70 KB (two CPUs) to `beam.com`: exqlite does not bring a second
SQLite. The NIF of argon2_elixir adds about 60 KB (two CPUs).

## WebAssembly

`beam.com` runs WebAssembly modules and WASI preview 1 programs with
[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime) (the
interpreter, linked into `beam.com`). The `wasm` application is in the
zip. When the code calls `wasm`, the builder puts it into the program:

```erlang
{ok, Mod} = wasm:compile(Bytes),                 % the bytes of a .wasm file
{ok, Inst} = wasm:instantiate(Mod),              % or wasm:instantiate(Bytes)
true = wasm:function_exists(Inst, "add"),
{ok, [42]} = wasm:call_function(Inst, "add", [40, 2]),  % i32/i64: integers, f32/f64: floats
{ok, Bin} = wasm:read_binary(Inst, Offset, Len), % the default memory
ok = wasm:write_binary(Inst, Offset, Bin),
{ok, Bytes} = wasm:memory_size(Inst),
{ok, OldPages} = wasm:memory_grow(Inst, 1),      % 64 KiB pages

%% A WASI program (from Rust, Go, Zig, C, ...): argv, env and directories.
{ok, ExitCode} = wasm:run(Bytes, #{args => ["prog", "arg"],
                                   env => #{"KEY" => "value"},
                                   preopens => #{"/" => "."}}),
%% The same in two steps: instantiate with the WASI options, then start.
{ok, Inst2} = wasm:instantiate(Bytes, #{}, #{args => ["prog"]}),
{ok, ExitCode2} = wasm:start(Inst2).
```

The names come from APIs that you may know already:

| `wasm` | From |
|---|---|
| `compile/1`, `instantiate/1,2,3` (a module or its bytes, the imports, the options) | the WebAssembly JavaScript API (`WebAssembly.compile`, `WebAssembly.instantiate`) |
| `call_function/3`, `function_exists/2`, `read_binary/3`, `write_binary/3` | [wasmex](https://hexdocs.pm/wasmex) (Elixir) |
| `memory_size/1` (bytes), `memory_grow/2` (pages; gives the old size) | `WebAssembly.Memory` |
| the options `args`, `env` and `preopens`, and `start/1` | [`node:wasi`](https://nodejs.org/api/wasi.html) |
| `run/2` | `wasmtime run` |

The imports must be `#{}` for now: host functions (Erlang functions
that the module calls) are not supported yet.

[`tests/programs/wasm_check.erl`](../tests/programs/wasm_check.erl) tests
calls, traps, memory and a WASI program, and runs a `.wasm` file that you
give it. CI runs it on each platform with a Go program
([`tests/programs/hello_go`](../tests/programs/hello_go), `GOOS=wasip1`).
WAMR adds about 0.6 MB (two CPUs). Build with `WASM=0` to leave it out.

Go resolves relative paths from `/`, so give the directory of a Go
program as `"/"` in `preopens`.

With `--target wasm32`, the program runs in the WebAssembly runtime,
which has no WAMR. There, the builder puts a module `wasm` with the same
API in the release, and the engine of the host runs the modules: V8 on
Deno, and the engine of the browser in a web page. The differences:

- A WASI program has no preopens, and its standard input is empty.
- The standard output and the standard error of a program go to the
  group leader of the caller when the call returns.
- A Cloudflare Worker cannot compile WebAssembly at run time, so there
  `wasm:compile/1` gives `{error, Reason}`.
- The code of a module runs on the thread of the host: a function that
  does not return stops the VM.

The notebook
[`docs/notebooks/webassembly_programs.livemd`](notebooks/webassembly_programs.livemd)
runs a module and a C program in this way.
