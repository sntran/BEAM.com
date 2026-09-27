# Roadmap

This file records the direction of BEAM.com and the decisions behind it.
Each item is done in small steps, and CI validates each step on all
platforms.

## Done

- ERTS (OTP 29.1.1) as one Actually Portable Executable, with a release
  in its zip. Tested on Linux, macOS, Windows, FreeBSD, NetBSD and
  OpenBSD 7.3, on x86_64 and aarch64.
- Static `crypto` and `asn1` NIFs with OpenSSL 4.0.2.
- TLS (`ssl`) with verification against the certificates of the OS,
  also on Windows (exported from the Windows store at start).
- Port programs on macOS and the BSDs (fd passing in the native
  `cmsghdr` layout).
- A sandbox for programs: `beam.com build --allow-read ... --allow-net`,
  the permission flags of Deno (with Cosmopolitan's `pledge()` and
  `unveil()`; Linux and OpenBSD). The launcher applies them before ERTS
  starts its threads. They replace the first flags, `--pledge` and
  `--unveil`: the names of OpenBSD were foreign to most users.
- `beam.com build` of `.yrl`, `.xrl` and ASN.1 files (with `parsetools`
  and `asn1ct` in the zip).
- `beam.com build`: no Erlang installation needed. It compiles one
  `.erl` file with `main/1`, or an application directory, selects the
  OTP applications that the code needs (from the `.app` file and the
  imports of the compiled code), makes the release with `systools`, and
  writes a new executable with the release in its zip. `beam.com`
  carries `compiler`, `sasl`, `crypto`, `asn1`, `public_key`, `ssl` and
  `inets` for this. BEAM.com warns when `start_erl.data` names another
  ERTS version.

## Probe results

### SQLite (default on, `SQLITE=0` to leave it out)

- The `esqlite` NIF (Apache-2.0) with the SQLite 3.53.4 amalgamation is
  linked into the emulator as a static NIF, the same way as `crypto`.
  The `esqlite` application is in the zip, and `beam.com build` selects
  it when the code calls `esqlite3`.
- Size: SQLite and the NIF add about 1.8 MB to the emulator for the two
  CPUs (compiled with `-Os`, as esqlite does; 2.8 MB with `-O2`). The
  cost is in each program that is made from that `beam.com`, also when
  the program does not use SQLite, because the NIF is in the emulator.
- CI runs a SQLite program (an in-memory database and a database file)
  on each platform.
- Default: on, since the probe. SQLite is small, and a database in the
  one file is useful for many programs.
- Why esqlite, and not SQLite alone: Erlang code cannot call C
  functions directly. A NIF must convert the terms and hold the
  database handles as resources, and esqlite does this in one C file
  (about 1300 lines). SQLite itself is compiled directly with `cosmocc`
  (the amalgamation of sqlite.org, not the older copy in esqlite). An
  own NIF (as for `wasm`) is possible later, if esqlite does not fit.

### WebAssembly (default on, `WASM=0` to leave it out)

- WAMR 2.4.5, the fast interpreter with WASI preview 1, is linked into
  the emulator as a static NIF. It adds about 0.6 MB for the two CPUs.
- The Erlang API does not show WAMR types. Its names come from APIs
  that users know: the WebAssembly JavaScript API (`compile/1`,
  `instantiate/1,2,3`), wasmex (`call_function/3`, `function_exists/2`,
  `read_binary/3`, `write_binary/3`), `WebAssembly.Memory`
  (`memory_size/1`, `memory_grow/2`) and `node:wasi` (the options
  `args`, `env`, `preopens`, and `start/1`); `run/2` as `wasmtime run`.
- Tested on each platform: calls with i32 and f64, traps, memory, a
  hand-made WASI module, and a Go program (`GOOS=wasip1`: arguments,
  environment, files).
- Problems found: see W1 to W3 in `docs/UPSTREAM.md` (the GS base, the
  generic trampoline, the fat build) and C19, C20.
- Next for WebAssembly: host functions (Erlang functions that a module
  can import), a time limit for calls, stdout/stderr to Erlang, SIMD
  (SIMDe), and later the component model and WASI preview 2 (see the
  notes below).

Notes on WASI preview 2: WAMR has no component model or WASI preview 2
yet (checked on WAMR HEAD of 2026-09-21, release 2.4.5). To not be stuck
on preview 1: the Erlang API is ours and hides the runtime. The
component model is designed so that a host can build it on a core
WebAssembly engine (as `jco` does in JavaScript), so a component layer
can be added on WAMR, or the runtime can be replaced.

### JIT (build flag `JIT=1`)

- BeamAsm in one fat file: the x86 backend in the x86_64 half and the
  arm backend in the aarch64 half (the default `beam.com`, 40 MB). See
  `docs/JIT.md`.
- The native stack for Erlang code is off, and asmjit has no
  precompiled header. On macOS arm64, `MAP_JIT` and the per-thread write
  permission are selected at run time.

## Next, in this order

### 1. JIT (BeamAsm): the default, and W^X

- Done: the fat JIT is the default `beam.com`, and `beam-emu.com` has
  the interpreter (`JIT=0`).
- Done: W^X. Measured in CI (`tests/programs/jit_maps.erl`): asmjit
  already uses dual mapping (`shm_open()`) under Cosmopolitan, with no
  writable and executable page, on Linux, FreeBSD, NetBSD and macOS
  x86_64; macOS arm64 uses `MAP_JIT`; the OpenBSD kernel enforces W^X
  itself. See `docs/JIT.md`.

### Later: more for `beam.com build`

- Done: Hex packages (the `deps` of `rebar.config`, `rebar.lock`,
  checksums, a cache), with `httpc` and TLS in `beam.com`.
- Done: Elixir. Evaluated first: Elixir 1.20.4 compiles with the
  Erlang/OTP 29.1.1 of this build; `elixir`, `eex`, `logger` and `mix`
  are 10 MB of beam files, 2.7 MB without debug information and docs,
  and 1.8 MB in the zip. `beam.com build` compiles one Elixir file with
  `main/1`, and Mix projects (read with Mix), with Hex packages in
  Elixir and `mix.lock`.
- Done: the tools of Elixir. `beam.com` runs `mix`, `iex`, `elixir` and
  `elixirc` (with `ex_unit` and the docs), as its first argument or by
  the name of the file (`mix.com`, `iex.com`, `elixir.com`,
  `elixirc.com`: the same file under other names), and escripts.
  Programs are built without docs and debug information (−7.7 MB).
- Next: `mix release` (it needs ERTS on disk), and the options of the
  Elixir scripts that change the `erl` command (`--erl`).
- Done: Phoenix from source with the tools (`iex.com -S mix
  phx.server`): `beam.com` has `xmerl` and `runtime_tools`, and CI runs
  a new Phoenix app on Linux.
- Done: distributed Erlang and remote shells: `epmd` is in the file,
  and starts only for `-sname`, `-name` and `-remsh`; `beam.com` takes
  the flags of `erl` (`beam.com -sname me -remsh app`); a program whose
  release has a node name has `app.com remote`.
- Done: a file watcher in the file, as `inotifywait` (inotify on Linux,
  a comparison of the files on the BSDs), which the tools give to
  `file_system`: `phoenix_live_reload` without `inotify-tools`.
- Done: the watcher as `mac_listener` for `file_system` on macOS, and
  kqueue on macOS and the BSDs: a change starts the comparison at once
  (the comparison every interval stays, for the changes that kqueue
  does not see).
- Next: the watcher on Windows; reload of new code in a running program
  when its file changes.
- Done: the NIFs of `exqlite` 0.41.0 (`--database sqlite3`, with the
  SQLite that is in `beam.com`) and of `bcrypt_elixir` 3.3.2
  (`phx.gen.auth`), linked into `beam.com` as static NIFs, so that the
  packages from Hex work unchanged. exqlite uses the SQLite of esqlite,
  so both NIFs add only about 70 KB (two CPUs). The tools set `MAKE` to
  a `make` of the file that does nothing for these two packages: they
  compile without `make` and a C compiler. CI runs a Phoenix app with SQLite and
  `phx.gen.auth` on Linux (`ecto.migrate`, an account with a password,
  a registration over HTTP).
- Next for Phoenix: `config/runtime.exs` and `priv/static` in
  `beam.com build`, for a Phoenix app in one file.
- Done: command line programs, for larger projects (for example an
  orchestration tool with a sandbox worker): the `main/1` of an application
  (`--main`, or the escript of `rebar.config` or `mix.exs`); behaviours
  and parse transforms compiled first; `priv` directories copied to a
  cache when other programs must read them (an executable in `priv`, or
  `--extract-priv`); erl mode (a link named `erl`, or `BEAM_COM_ERL=1`)
  and `-beam_com_exe`, so that a program can start a new VM from its
  own file.
- Next: git dependencies (`{git, URL, {ref, R}}` in `rebar.config`,
  `git:`/`github:` in `mix.exs`), with the lock entries of rebar3 and
  Mix.
- Not planned: NIF dependencies, rebar3 plugins.

### More from Cosmopolitan

- Done: crash reports. `ShowCrashReports()` prints the signal, the
  registers and a backtrace with function names when the emulator dies
  on a fatal signal (`BEAM_COM_CRASH_REPORTS=0` turns it off). It
  installs handlers only for the fatal signals (`SIGSEGV`, `SIGBUS`,
  `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGTRAP`, `SIGQUIT`); ERTS sets its
  own handlers after it, so for a signal that ERTS handles, its own
  handler runs.
  A `SIGSEGV` sent with `kill` does not stop the process (the handler
  returns for a signal from a user); the test uses `erlang:halt(abort)`.
- Done: a faster start. The code of `kernel` and `stdlib` is stored
  without compression (the rest stays compressed): 2 MB more, and the
  start is about 50 ms (27%) faster. A zip with no compression at all
  is about 21 MB larger, so only the modules of the boot are stored.
- Done: `beam.com build --target TARGET` writes a native ELF (Linux,
  FreeBSD) or Mach-O (macOS x86_64) file, with the same bytes as
  `assimilate`. There is no native form for Apple Silicon (APE files run
  there only with the APE loader). The flag was `--native` first; it is
  `--target` now, with the target triples of Rust and `deno compile`
  (and the short names of Zig), as other compilers name it.
- Used already: the zip file system (`/zip`), the fat x86_64 and
  aarch64 file, `.args`, the `--strace` and `--ftrace` flags, and
  `GetProgramExecutableName()` for the helper programs.

## Watch list (checked 2026-09-26)

What other projects did recently, and what it means for BEAM.com. All
the parts of the build are at their latest stable release (cosmocc
4.0.2, Erlang/OTP 29.1.1, Elixir 1.20.4, OpenSSL 4.0.2, SQLite 3.53.4,
WAMR 2.4.5).

- **Cosmopolitan master** has fixes that are not in a release yet: in
  threads and locks (`EINTR` in condition variables, the lock on NetBSD,
  the locks on Windows and XNU). Take the next cosmocc release when it
  comes, and run the stress tests again (see C25 in `docs/UPSTREAM.md`).
  C25 and C26 (`close()` and the fd table, `docs/UPSTREAM.md`) are
  candidates to send upstream.
- **OpenBSD in CI stays on 7.3**: the CI action has OpenBSD 7.3 to 7.9,
  but Cosmopolitan supports OpenBSD 7.3 and earlier only (see "Platform
  status" in the README, and C14 in `docs/UPSTREAM.md`). BEAM.com does
  not work around this: OpenBSD 7.4 and later accept system calls only
  from the places that the kernel records (`pinsyscalls`), which needs a
  change in Cosmopolitan itself (its system calls through `libc.so`, as
  on Apple Silicon, or a table of system calls in a native file). We
  wait for support in Cosmopolitan.
- **OTP 29 TLS**: the default key exchange of `ssl` is now the hybrid
  post-quantum group `x25519mlkem768`. Next: a check in `tls_check` that
  a TLS 1.3 connection uses it with the static OpenSSL 4.0.2.
- **OTP deprecates `.ez` archives**: no effect; BEAM.com reads its zip
  as a file system (`/zip`), not as code archives.
- **Elixir 1.20** can evaluate module bodies instead of compiling them
  (`module_definition: :interpreted`). A probe: read `mix.exs` that way,
  which can make a build of a Mix project faster.
- **hex_core 0.19** has a security fix. BEAM.com has its own Hex client
  (`beam_com_hex`), so check whether the same problem applies to it.
- **Gleam 1.18**: its compiler is a native program, not Erlang, so
  `beam.com build` cannot compile Gleam. A Gleam project can give its
  Erlang output (`gleam export erlang-shipment`) to `beam.com build`; a
  probe of this is possible.
- **Burrito 1.6**: see "Nothing is extracted" in the README for the
  comparison. BEAM.com now copies a `priv` directory only when other
  programs must read its files.
- **AtomVM 0.7** (alpha): a small VM for microcontrollers; not a
  replacement for ERTS here.

## Decided against

- `beam_com:pledge/1` and `unveil/2` for Erlang code: on Linux, seccomp
  and Landlock apply to the calling thread and the threads that it
  starts later, and the threads of the VM exist before any Erlang code
  runs. A call from Erlang would restrict one scheduler thread only. The
  rules come from the build (`--allow-*`) and the launcher applies
  them.

- Loading native per-platform NIF libraries (`cosmo_dlopen`): it breaks
  "build once", and the calling conventions and exported symbols make
  it fragile.
- Carrying cosmocc in `beam.com` for user NIFs: it is about 120 MB.
  A downloadable "NIF SDK" (cosmocc and the ERTS objects) is possible
  later.
