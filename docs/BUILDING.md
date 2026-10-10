# Build BEAM.com

You do not need to build BEAM.com to use it: download `beam.com` from
the releases (see the README). This file is for a change of BEAM.com, or
for a custom build.

## Build

You need Linux (x86_64), `git`, GNU make 4, `perl`, `curl`, `zip` and
`unzip`. The [`Makefile`](../Makefile) downloads the sources, applies the
patches, builds a small OTP and makes `build/beam.com`:

```sh
make toolchain               # downloads cosmocc, with its own GNU make 4.4
build/cosmocc/bin/make       # all the steps
```

Any GNU make 4 works. CI uses the make of cosmocc, so the build does not
depend on the make of the host.

The build downloads:

- cosmocc 4.0.2 (the compiler and Cosmopolitan Libc);
- the source of Erlang/OTP 29.1.1, OpenSSL 4.0.3, SQLite 3.53.4,
  esqlite, WAMR 2.4.5 and Elixir 1.20.4;
- the hex.pm packages whose NIFs it links (exqlite, bcrypt_elixir and
  argon2_elixir), with a check of their SHA-256;
- emsdk 6.0.10, for the WebAssembly runtime of `--target wasm32`.

The steps, in order. The code of each step is in
[`scripts/steps.sh`](../scripts/steps.sh), and the Makefile runs them:

| Step | Needs | What it does |
|---|---|---|
| `toolchain` | | Downloads cosmocc. |
| `openssl` | `toolchain` | Builds a static `libcrypto`. |
| `otp` | | Clones OTP and applies `patches/otp/*.patch`. |
| `configure` | `otp`, `openssl` | Configures OTP for Cosmopolitan. |
| `sqlite` | `configure` | Builds SQLite and the esqlite NIF (nothing with `SQLITE=0`). |
| `nifs` | `sqlite` | Builds the NIFs of exqlite, bcrypt_elixir and argon2_elixir (nothing with `ELIXIR=0`). |
| `wasm` | `configure` | Builds WAMR (the interpreter and the AOT loader), the wasm NIF and the loader of NIF libraries in WebAssembly ([`NIFS.md`](NIFS.md)) (nothing with `WASM=0`). |
| `make` | `nifs`, `wasm` | Builds a small OTP: the emulator and the OTP applications. |
| `elixir` | `make` | Downloads and builds Elixir (nothing with `ELIXIR=0`). |
| `release` | `elixir` | Installs an OTP release tree, for its boot scripts. |
| `multicall` | `release` | Links the emulator again with the helper programs (`erl_child_setup`, `inet_gethost`, `epmd`, the file watcher) and the static NIFs. |
| `wasm_runtime` | `multicall` | Builds the WebAssembly runtime with Emscripten (`wasm/erts/build.sh`). |
| `bundle` | `wasm_runtime` | Writes `build/beam.com`: the emulator and its zip. |
| `test` | `bundle` | Runs `beam.com`, and builds and runs a program with it. |
| `unit` | `bundle` | Runs the tests of the Mix project with the `beam.com` of the build (`beam.com mix test --cover`). |

`make STEP` runs the step and each step that it needs first. Each step
writes a stamp in `build/stamps/`. A step runs again only when:

- a step that it needs ran again;
- one of its files in this repository changed (for example, `src/` for
  `bundle`, and `patches/otp/` for `otp`);
- a setting changed (`build/stamps/config`), for example `JIT=0`.

`test` and `unit` run each time. `make redo-STEP` runs a step again with
no change of its inputs, for example after a change of
`scripts/steps.sh`. The steps run one at a time, because they share the
OTP tree. Each step uses `JOBS` processes.

The settings are environment variables or variables of the make command
line. See the top of [`scripts/steps.sh`](../scripts/steps.sh): the
versions, `JIT=0` (the interpreter, `beam-emu.com`), `SQLITE=0`,
`WASM=0`, `ELIXIR=0` and `WASM_RUNTIME=none`. For example:

```sh
build/cosmocc/bin/make JIT=0 OUT=build/beam-emu.com
```

The OTP build runs the APE tools that it builds. If Linux cannot run
APE files directly, register the APE loader with `binfmt_misc` (see
[the workflow](../.github/workflows/build.yml)).

## A custom build

The default `beam.com` has a fixed set of OTP applications, and no Hex
or rebar3. A custom build can have more:

- `OTP_APPS="mnesia eldap"`: more OTP applications in the zip (their Erlang
  code; the C code of an application, as the port programs of `os_mon`,
  is not built).
- `HEX=1`: Hex in the zip (the newest, from `mix local.hex`). The tools
  of Elixir have it in their code path, so `mix.com deps.get` needs no
  `mix local.hex`. Only with `ELIXIR=1`.
- `REBAR3=1`: rebar3 in the zip (the newest release). A copy or a link
  named `rebar3.com` (or `beam.com rebar3`) runs it, and `mix.com` uses
  it for the dependencies that are rebar3 projects (`MIX_REBAR3`), so
  `mix local.rebar` is not needed either.
- `EXTRA_NIFS="picosat_elixir"`: the NIFs of more hex.pm packages,
  linked as those of `bcrypt_elixir` and `argon2_elixir` are (see
  "Phoenix from source" in [`ELIXIR.md`](ELIXIR.md)). The list is in
  `hex_nif_recipe()` of `scripts/steps.sh`: `picosat_elixir` (the SAT solver of
  Ash). Only with `ELIXIR=1`.

With `HEX=1 REBAR3=1`, a clone of a project, `mix.com deps.get` and
`iex.com -S mix phx.server` work as with a normal Elixir installation.

You do not need to build it yourself: open an issue with the form **A
custom build of beam.com**. CI builds the file with your choices
([the workflow](../.github/workflows/custom-build.yml)), puts it on the
issue (a download of the run, with a GitHub account, for 90 days), and
closes the issue. A custom build has the WebAssembly runtime too
(`--target wasm32`), and CI builds and runs a program with it before the
answer. It is built from `main`, and the answer names the commit.

## The runtime directory (internal)

`beam.com INPUT -o DIR --target wasm32` (an output that does not end
with `.com`) writes the full directory of the WebAssembly runtime: `beam.wasm`, `worker.js` and the files of each host,
with a release of INPUT. [`scripts/npm.sh`](../scripts/npm.sh) makes the
`runtime/` of the npm package from such a directory (of any INPUT: the
runtime does not depend on it), and some tests use it. It is an internal
step: its files and options can change in any version. To deploy an
app, use `app.com` and the npm package (see
[`WORKERS.md`](WORKERS.md)). With `-o FILE.com`, `--target wasm32` writes
`app.com` with only its edge part, and no native program.

| File | What |
|---|---|
| `wrangler.jsonc`, `worker.js`, `beam.mjs`, `beam.wasm` | The runtime Worker (`NAME`): the VM, with no program. |
| `release/wrangler.jsonc`, `release/app.js`, `release/release.bin` | The Worker with the release (`NAME-release`, with no public URL). The runtime Worker gets `release.bin` from it at the first request of an isolate. |
| `durable.js`, `wrangler.durable.jsonc` | The same runtime in one Durable Object (`NAME-durable`): one VM for all the requests, with SQLite storage. |
| `global.js`, `wrangler.global.jsonc` | The runtime Worker with the release and a snapshot of the build in it. The global scope restores the VM before the first request. |
| `durable-global.js`, `wrangler.durable-global.jsonc` | The Durable Objects, with a spare VM that the global scope restores. |
| `worker.capnp` | Both Workers for `workerd`. |
| `tcp-proxy.mjs` | A local TCP port for a listener of the program (see "Incoming TCP" in `WORKERS.md`). |
| `licenses/` | The license texts of the software in `beam.wasm`. Wrangler uploads them with the runtime (about 80 KB). |
| `deno.js`, `deno.json`, `deno/` | The same runtime on Deno and Deno Deploy. |
| `browser.js`, `browser/` | The same runtime in a web page. |
| `page/` | A static site of the release, with its own `release.bin`. `--page` writes the site of an `app.com` (see "A static site for any app" in `WORKERS.md`). |

The build also runs the release one time on this computer, to find the
modules of its boot (`BEAM_COM_WASM_NATIVE_RUN=0` turns this off).
[`wasm/snapshot/snapshot.mjs`](../wasm/snapshot/snapshot.mjs) makes a
snapshot of such a directory, and `global.js` restores it in the global
scope. For an `app.com`, `npx beam.com --snapshot` does the same.

## Continuous integration

[The workflow](../.github/workflows/build.yml) has these jobs:

1. **Build** and **Build the interpreter**: `beam.com` (the JIT) and
   `beam-emu.com` (the interpreter), on Ubuntu with cosmocc. A cache
   keeps the WebAssembly runtime (the step `wasm_runtime`, about 4
   minutes). The step uses it only when the SHA-256 of its inputs (the
   file `build/wasm-runtime/inputs`) is the same, so a local build with
   another runtime builds it again.
2. **Unit tests**: `scripts/steps.sh unit` on the `beam.com` of the
   build, in their own job, so that the other jobs do not wait for
   them.
3. **Add a rebar3 release**: a release of `examples/greeter` and of two
   check programs, made with a normal Erlang/OTP and rebar3, and added to
   copies of `beam.com` with `zip`.
4. **Run on ...**: the behavior tests ([`tests/run.sh`](../tests/run.sh),
   [`tests/run.ps1`](../tests/run.ps1)) and the benchmarks on Linux
   (x86_64, aarch64), macOS (arm64, x86_64), Windows, FreeBSD, NetBSD and
   OpenBSD 7.3. See [`TESTING.md`](TESTING.md).
5. **Publish the edge binary**: after a merge to `main`, the prerelease
   `edge` gets the new `beam.com`.
6. **Publish the release**: for a tag `vX.Y.Z`, the release of the tag
   gets `beam.com`, `beam-emu.com`, the tarball of the npm package and
   `SHA256SUMS`, and npm gets the same tarball. A run of this job again
   puts its files on the release that is there, and skips npm when npm
   has the version.

For a tag, the job **Find a tested run of this commit** comes first. It
waits for the run of the push of the same commit to `main`. When that run
passed, the tag run builds and tests nothing: the release job takes
`beam.com` and `beam-emu.com` of that run, and the release takes about
two minutes. When there is no such run, or it did not pass, the tag run
builds and tests the commit, as a run of `main` does (about 25 minutes).

[Another workflow](../.github/workflows/pages.yml) publishes the site of
BEAM.com on GitHub Pages ([`site.sh`](site.sh)): these docs as ExDoc
makes them, the Erlang shell of `examples/worker` at `repl/`, and
Livebook at `livebook/` ([`page.sh`](../wasm/livebook/page.sh)). It uses
the `edge` binary, and runs after each change of the docs on `main` and
after each run of CI on `main`. The release of Livebook stays in the
cache of the workflow until its files or the versions of `beam.com`
change.

A run starts for each pull request (and again for each new push to it;
the run of the older commit stops), for each push to `main`, and for each
tag `v*`. A change of the docs only (Markdown files, `docs/`, the issue
forms) starts no run. To test a branch without a pull request, run the
workflow by hand (Actions, "Run workflow") with no `release`.

## Make a release

1. Set the version in each file that has it, write its section
   (`## X.Y.Z`) in [`CHANGELOG.md`](../CHANGELOG.md), and merge the
   change to `main`. The section goes at the start of the notes of the
   release. The files: `src/beam_com/beam_com.app.src`, `package.json`,
   the `beam.com` dependency of `examples/*/package.json`, and the URL of
   the npm package in `README.md`.
   [`scripts/version.sh`](../scripts/version.sh) checks them, and CI runs
   it for each change.
2. Start the release in one of two ways:
   - Run the workflow by hand on `main` (Actions, "Build and test
     BEAM.com", "Run workflow"), with the version in the field
     `release`, for example `0.1.0`. The job makes the annotated tag
     `v0.1.0` on the commit of `main`. It stops when the version is not
     the version of `beam_com.app.src`, and when the tag is on another
     commit.
   - Or push a tag with the same version on the merge commit: `git tag -a
     v0.1.0 -m "BEAM.com 0.1.0" && git push origin v0.1.0`. The job
     stops when the commit of the tag is not on `main`.
3. The run takes the files of the run of `main` for that commit (it
   waits for that run when it has not ended), and then publishes the
   release of the tag. With no passed run of `main` for the commit (for
   example a merge that changes only docs), the run builds and tests the
   commit itself, and each test job must pass. The job stops when the
   tag and the version differ, and when `CHANGELOG.md` has no section of
   the version. Before the publish, it runs the provenance check of
   `pages-app.yml` on its `beam.com`. A re-run of a run by hand finds its
   tag, and goes on.
4. npm publishes with trusted publishing: the trusted publisher of the
   package `beam.com` on npmjs.com is the workflow `build.yml` of
   `sntran/BEAM.com`, with no environment. The workflow needs no npm
   token.
