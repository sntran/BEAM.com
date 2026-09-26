# Roadmap

This file records the direction of BEAM.com and the decisions behind it.
Each item is done in small steps, and CI validates each step on all
platforms.

## Done

- ERTS (OTP 29.1.1) as one Actually Portable Executable, with a release
  in its zip. Tested on Linux, macOS, Windows, FreeBSD, NetBSD and
  OpenBSD 7.3, on x86_64 and aarch64.
- Static `crypto` and `asn1` NIFs with OpenSSL 3.5.8.
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

## Next, in this order

### 1. SQLite probe

Build SQLite as a static NIF (for example the one of `exqlite` or
`esqlite`) behind a build flag, and measure the size. Estimate: about
3 MB for the two CPUs. Node.js and Bun include SQLite too. The default
is decided after the measurement.

### 2. WebAssembly (and WASI)

A static NIF with a WebAssembly runtime, so that users can put portable
native code (`.wasm`, from Rust, Go, Zig, C...) in the zip.

- Runtime: WAMR (Bytecode Alliance, C, Apache-2.0), interpreter first.
  Its WASI layer uses POSIX, which Cosmopolitan gives on every platform.
- WASI preview 1 first (`wasm32-wasip1`, `GOOS=wasip1`, Zig, TinyGo).
  WAMR has no component model or WASI preview 2 yet (checked on WAMR
  HEAD of 2026-09-21, release 2.4.5).
- To not be stuck on preview 1: the Erlang API (`wasm:load/1`,
  `instantiate/2`, `call/3`, memory access) is ours and hides the
  runtime. The component model is designed so that a host can build it
  on a core WebAssembly engine (as `jco` does in JavaScript), so a
  component layer can be added on WAMR, or the runtime can be replaced.
- Steps: WAMR with cosmocc; pure function calls from a release; a WASI
  program (arguments, environment, stdout); memory and binaries, dirty
  schedulers and limits.

### 3. JIT (BeamAsm) probe

- The two CPU backends (x86_64 and aarch64) must be selected per CPU in
  the fat build (wrapper files and the generated files for both).
- Executable memory must be selected at run time for each OS (dual
  mapping or single mapping). OpenBSD enforces W^X.
- Good: Cosmopolitan uses the System V calling convention on every OS,
  so the Unix path of BeamAsm is also correct on Windows.
- Risk: the native stack and `sigaltstack` under the Windows signal
  emulation.
- Fallback: two files, `beam.com` (JIT) and `beam-emu.com` (interpreter).
- Steps: x86_64 JIT on Linux; the other x86_64 platforms; the aarch64
  half; the fallback.

### Later: more for `beam.com build`

- Hex packages (source), fetched with the `httpc` and TLS support that
  `beam.com` already has, and a lock file.
- `.yrl`/`.xrl` (`parsetools`) and `.asn1` files; Elixir sources.
- Not planned: NIF dependencies, rebar3 plugins.

## Decided against

- Loading native per-platform NIF libraries (`cosmo_dlopen`): it breaks
  "build once", and the calling conventions and exported symbols make
  it fragile.
- Carrying cosmocc in `beam.com` for user NIFs: it is about 120 MB.
  A downloadable "NIF SDK" (cosmocc and the ERTS objects) is possible
  later.
