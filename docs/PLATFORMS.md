# Platforms and limits

One file runs on all the systems below, on x86_64 and aarch64. CI tests
each row, except WSL2 (see below) and OpenBSD 7.9.

## Platform status

| Platform | How to run | beam.com, greeter | crypto | TLS | Port programs |
| --- | --- | --- | --- | --- | --- |
| Linux x86_64 | `sh ./beam.com` (or `./beam.com` with the APE loader in binfmt_misc) | ✅ | ✅ | ✅ | ✅ |
| Linux aarch64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| WSL2 (Linux x86_64) | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| macOS arm64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| macOS x86_64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| FreeBSD | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| NetBSD | `ape-x86_64.elf ./beam.com` (its `sh` cannot read APE files) | ✅ | ✅ | ✅ | ✅ |
| OpenBSD 7.3 | `ape-x86_64.elf ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| OpenBSD 7.9 | Not supported by Cosmopolitan (7.3 or earlier only) | ❌ | ❌ | ❌ | ❌ |
| Windows x86_64 | `beam.exe` (a copy with an `.exe` name) | ✅ | ✅ | ✅ | ❌ |

`ape-x86_64.elf` is the APE loader from cosmocc (`bin/ape-x86_64.elf`).
On NetBSD and OpenBSD, also install it where Cosmopolitan's `execve()`
looks for it (`/usr/bin/ape` or `~/.ape-1.10`): BEAM.com starts its
helper programs by executing itself, and without a loader Cosmopolitan
falls back to `sh`.

On WSL2, the binfmt_misc entry `WSLInterop` gives each file that starts
with `MZ` (an APE file too) to Windows. BEAM.com does not let the kernel
start its own APE file (see "One file, many programs" in
[`INTERNALS.md`](INTERNALS.md)), so you do not
have to disable `WSLInterop` (`echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop`,
as the error message of Cosmopolitan says). Start the file with
`sh ./beam.com`: `./beam.com` also goes to Windows. CI does not run on
WSL2: the WSL check of `tests/run.sh` makes an entry such as
`WSLInterop` in a user namespace of Linux (Linux 6.7 or later), and
runs the checks there.

On Windows, `os:type()` is `{unix, windows}`, and port programs do not
work: `open_port({spawn, ...})`, `os:cmd/1` and native name lookups
fail with `enotsup` (see C16 in [`UPSTREAM.md`](UPSTREAM.md)).
At start, BEAM.com therefore gives kernel an inetrc with the name servers
and the hosts file of Windows, so that names are resolved with Erlang's
own DNS client (`ERL_INETRC` points at it; set `ERL_INETRC` yourself to
use your own file), and it exports the trusted root certificates of
Windows to a PEM file that `public_key:cacerts_get/0` reads
(`-public_key cacerts_path File`; give that parameter yourself to use
your own file). Both files are in the temp directory of the user and
are removed when the node stops.

## Known limits

- No `socket` NIF, no NIFs or drivers in shared objects
  (Cosmopolitan cannot make them). The native NIFs are the static NIFs
  in `beam.com` (`crypto`, `asn1`, `wasm`, `esqlite`, and the Elixir
  packages `exqlite`, `bcrypt_elixir` and `argon2_elixir`). Other NIF
  libraries work as WebAssembly files ([`NIFS.md`](NIFS.md)).
- WebAssembly: the interpreter, and AOT files of WAMR (no JIT), WASI
  preview 1 only, no SIMD, no threads, and no component model yet.
- Distributed Erlang is tested on Linux, macOS and the BSDs, not on
  Windows yet.
- Windows: SQLite (esqlite) takes a path with a drive (`C:\db\x.db`)
  as a relative path, because its Unix VFS runs there; give a relative
  path, or the form of Cosmopolitan (`/C/db/x.db`).
- Windows: no port programs (no `os:cmd/1`, no `inet_gethost`; names
  are resolved with Erlang's DNS client, IPv4 name servers only).
- WSL2: start an APE file with `sh`. The kernel gives an APE file that
  it starts itself to Windows (`WSLInterop`): `./beam.com`, and an APE
  file that a shell starts (`os:cmd("other.com")`). BEAM.com starts its
  own helpers, and the APE files of `open_port({spawn_executable, ...})`,
  with the APE loader.
- `run_erl` does not work (there is no `mkfifo()`).
- A release that you add with `zip` brings the applications that it
  needs, when they are not in the zip of `beam.com` (pure Erlang ones
  only).
- A release must be for the same OTP as `beam.com` (29.1.1). BEAM.com
  writes a warning when `start_erl.data` names another ERTS version.
- `beam.com INPUT -o OUTPUT` takes only Hex packages (no git
  dependencies). For Elixir: no umbrella projects, no
  `config/runtime.exs`, no protocol consolidation. A release directory
  of `mix release` has none of these limits, with `--target wasm32`.
- For the limits of Cloudflare Workers (`--target wasm32`), see
  [`WORKERS.md`](WORKERS.md).
