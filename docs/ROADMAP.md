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
- The Erlang API is ours (`wasm:load/1`, `instantiate/2`, `call/3`,
  `run/3`, memory access), and it does not show WAMR types.
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
  arm backend in the aarch64 half (`beam-jit.com`, 42 MB). See
  `docs/JIT.md`.
- The native stack for Erlang code is off, and asmjit has no
  precompiled header. On macOS arm64, `MAP_JIT` and the per-thread write
  permission are selected at run time.

## Next, in this order

### 1. JIT (BeamAsm): the default, and W^X

- The fat JIT as the default `beam.com`, when it is green on every
  platform, with the interpreter as `beam-emu.com` or as a build option.
- Dual mapping (W^X) in asmjit under Cosmopolitan: memfd on Linux, a
  file elsewhere (today it falls back to RWX memory, except on macOS
  arm64, which uses `MAP_JIT`).

### 2. pledge() and unveil()

Cosmopolitan has `pledge()` (Linux with seccomp-BPF, and OpenBSD) and
`unveil()` (Linux with Landlock, and OpenBSD). A program could give up
what it does not need after its start, as OpenBSD daemons do.

- A static NIF with `beam_com:pledge(Promises)` and
  `beam_com:unveil(Path, Permissions)`, which return `{error, enotsup}`
  on the other systems.
- The mode that returns `EPERM` (not the one that kills the process), so
  a forbidden call is an Erlang error.
- To check first: that the filter covers all the threads of the VM, and
  which promises the VM needs at run time (for example `prot_exec` for
  the JIT, `proc exec` for port programs).
- Tests on Linux and on OpenBSD in CI.

### Later: more for `beam.com build`

- Hex packages (source), fetched with the `httpc` and TLS support that
  `beam.com` already has, and a lock file.
- `.yrl`/`.xrl` (`parsetools`) and `.asn1` files; Elixir sources.
- Not planned: NIF dependencies, rebar3 plugins.

### Later: more from Cosmopolitan

- Crash reports: `ShowCrashReports()` prints a backtrace (and the
  `cosmoaddr2line` command for a better one) when the emulator dies on
  a fatal signal. To check first: that it does not change how ERTS
  handles its own signals.
- A faster start: entries that are stored (not compressed) in the zip
  can be read without inflating them. Measured on Linux x86_64 with a
  zip without compression: `beam.com version` starts in about 100 ms
  instead of about 145 ms, but the file grows from 27.5 MB to 49 MB.
  To try: store only the modules that the boot loads.
- A native file for one platform, made with `assimilate` (a Mach-O file
  for macOS, an ELF file for Linux): no APE loader in `$TMPDIR`, and a
  macOS file that can be signed. As an option of `beam.com build`.
- Used already: the zip file system (`/zip`), the fat x86_64 and
  aarch64 file, `.args`, the `--strace` and `--ftrace` flags, and
  `GetProgramExecutableName()` for the helper programs.

## Decided against

- Loading native per-platform NIF libraries (`cosmo_dlopen`): it breaks
  "build once", and the calling conventions and exported symbols make
  it fragile.
- Carrying cosmocc in `beam.com` for user NIFs: it is about 120 MB.
  A downloadable "NIF SDK" (cosmocc and the ERTS objects) is possible
  later.
