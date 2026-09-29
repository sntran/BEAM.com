# Roadmap

This file records the direction of BEAM.com, and the decisions behind
it. Each change comes in small steps, and CI tests each step on all the
systems.

## What BEAM.com has now

- ERTS of Erlang/OTP 29.1.1 as one Actually Portable Executable, with
  the JIT (BeamAsm) for x86_64 and aarch64 in one file, and no page that
  is writable and executable. See [`JIT.md`](JIT.md).
- `beam.com INPUT` and `beam.com INPUT -o OUTPUT`: run and build `.erl`
  and `.ex` files, applications, rebar3 and Mix projects, with Hex
  packages, and with no Erlang installation. See
  [`PROGRAMS.md`](PROGRAMS.md).
- Elixir 1.20.4 and its tools in the file (`mix`, `iex`, `elixir`,
  `elixirc`, `escript`), and Phoenix from source with SQLite and
  `phx.gen.auth`. See [`ELIXIR.md`](ELIXIR.md).
- Static NIFs: `crypto` and `asn1` (OpenSSL 4.0.2), SQLite 3.53.4
  (esqlite and exqlite), WebAssembly (WAMR 2.4.5), bcrypt_elixir and
  argon2_elixir. See [`LIBRARIES.md`](LIBRARIES.md).
- A sandbox with the permission flags of Deno (Linux and OpenBSD). See
  [`SANDBOX.md`](SANDBOX.md).
- Native files for one system (`--target`), distributed Erlang with
  `epmd` in the file, a file watcher for `phoenix_live_reload`, and
  crash reports.
- Cloudflare Workers (`--target wasm32`): a second runtime (ERTS on
  WebAssembly with green threads on JSPI), Durable Objects, Ecto SQLite
  on D1 and Durable Objects, snapshots of the booted VM, tenants and
  instances. See [`WORKERS.md`](WORKERS.md).

## Next

### Programs

- Git dependencies (`{git, URL, {ref, R}}` in `rebar.config`,
  `git:`/`github:` in `mix.exs`), with the lock entries of rebar3 and
  Mix.
- `config/runtime.exs` and `priv/static` in `beam.com INPUT -o OUTPUT`,
  for a Phoenix app in one file.
- `mix release` with `include_erts: true`, and the options of the Elixir
  scripts that change the `erl` command (`--erl`).
- The file watcher on Windows, and a reload of new code in a running
  program when its file changes.
- A check of `beam_com_hex` against the security fix of hex_core 0.19
  (BEAM.com has its own Hex client).

### WebAssembly in Erlang code

- Host functions (Erlang functions that a module can import), a time
  limit for calls, and stdout and stderr to Erlang.
- SIMD, and later the component model and WASI preview 2. WAMR has no
  component model yet. The Erlang API hides the runtime, so a component
  layer can come on WAMR, or another runtime can replace it.

### Cloudflare Workers

- A test in CI that runs the Workers in `workerd` (CI builds them, and
  checks the files, but does not run them yet).
- Postgres through `wasm_tcp` (Postgrex over `gen_tcp` and `ssl`).
- Modules that load when the code server asks for them: this needs a
  runtime built with `-sSUPPORT_LONGJMP=wasm` (see EM4 in
  [`UPSTREAM.md`](UPSTREAM.md)).
- Rustler NIFs in the runtime, UDP and DNS through the host, and
  `Phoenix.PubSub` between Durable Objects.
- Incoming TCP through the `connect()` handler of Workers, when
  Cloudflare makes it available.

## Watch list (checked 2026-09-26)

All the parts of the build are at their latest stable release (cosmocc
4.0.2, Erlang/OTP 29.1.1, Elixir 1.20.4, OpenSSL 4.0.2, SQLite 3.53.4,
WAMR 2.4.5, emsdk 6.0.10).

- **Cosmopolitan master** has fixes that are not in a release yet: in
  threads and locks (`EINTR` in condition variables, the lock on NetBSD,
  the locks on Windows and XNU). Take the next cosmocc release when it
  comes, and run the stress tests again (C25 in
  [`UPSTREAM.md`](UPSTREAM.md)). C25 and C26 are candidates to send
  upstream.
- **OpenBSD 7.4 and later** accept system calls only from the places
  that the kernel records (`pinsyscalls`). This needs a change in
  Cosmopolitan itself (C14). CI stays on OpenBSD 7.3 until then.
- **The TLS of OTP 29** uses the hybrid post-quantum group
  `x25519mlkem768` by default. Next: a check that a TLS 1.3 connection
  uses it with the static OpenSSL 4.0.2.
- **Elixir 1.20** can evaluate module bodies in place of a compile
  (`module_definition: :interpreted`). A probe: read `mix.exs` that way,
  for a faster build of a Mix project.
- **Gleam**: its compiler is a native program, so `beam.com` cannot
  compile Gleam. A probe: give the Erlang output of a Gleam project
  (`gleam export erlang-shipment`) to `beam.com INPUT -o OUTPUT`.
- **WASI**: ERTS needs threads, and no WASI host gives the stack
  switching of the green threads yet. With stack switching in Wasmtime
  and other hosts, the same runtime could run there.

## Decided against

- `beam_com:pledge/1` and `unveil/2` for Erlang code: on Linux, seccomp
  and Landlock apply to the calling thread and the threads that it
  starts later, and the threads of the VM exist before any Erlang code
  runs. So the rules come from the build (`--allow-*`), and the launcher
  applies them before ERTS starts its threads.
- Native NIF libraries for each platform (`cosmo_dlopen`): they break
  "build once", and the calling conventions and exported symbols make
  them fragile.
- cosmocc in `beam.com`, for the NIFs of users: it is about 120 MB. A
  "NIF SDK" to download (cosmocc and the objects of ERTS) is possible
  later.
- A WebAssembly runtime from an x86-64 emulator (Blink): it runs all of
  OTP, but 400 to 550 times slower than native (see
  [`history/WASM-LOG.md`](history/WASM-LOG.md)).
