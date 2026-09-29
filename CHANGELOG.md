# Changes

The release job of CI puts the section of a version at the start of the
notes of its release.

## 0.1.0

The first release.

- Erlang/OTP 29.1.1 and Elixir 1.20.4 in one executable file for Linux,
  macOS, Windows, FreeBSD, NetBSD and OpenBSD, on x86_64 and aarch64,
  with the JIT (BeamAsm) for both CPUs. `beam-emu.com` has the
  interpreter.
- `beam.com INPUT` runs and `beam.com INPUT -o OUTPUT` builds `.erl` and
  `.ex` files, applications, and rebar3 and Mix projects, with Hex
  packages, and with no Erlang installation. `mix`, `iex`, `elixir`,
  `elixirc` and `escript` are in the file.
- Static NIFs: `crypto` (OpenSSL 4.0.2), SQLite 3.53.4 (esqlite and
  exqlite), WebAssembly and WASI (WAMR 2.4.5), bcrypt_elixir and
  argon2_elixir.
- A sandbox with the permission flags of Deno (`--allow-read`,
  `--allow-write`, `--allow-net`, `--allow-run`), on Linux and OpenBSD.
- `--target wasm32`: a second runtime, ERTS on WebAssembly with green
  threads on JSPI. One output runs on Cloudflare Workers (Durable
  Objects, D1, snapshots, tenants), on Deno Deploy (SQLite with its
  pages in Deno KV), and in a web page. Phoenix LiveView and Livebook
  run on it.
- The documentation is a set of Livebook notebooks that run in the
  browser: <https://sntran.github.io/BEAM.com/>.

See [`docs/PLATFORMS.md`](docs/PLATFORMS.md) for the known limits.
