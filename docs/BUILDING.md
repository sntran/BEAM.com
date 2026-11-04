# Build BEAM.com

You do not need to build BEAM.com to use it: download `beam.com` from
the releases (see the README). This file is for a change of BEAM.com, or
for a custom build.

## Build

You need Linux (x86_64), `git`, GNU make 4.3 or later, `perl`, `curl`,
`zip` and `unzip`. The [`Makefile`](../Makefile) downloads the sources,
applies the patches, builds a small OTP and makes `build/beam.com`:

```sh
make toolchain               # downloads cosmocc, with its own GNU make 4.4
build/cosmocc/bin/make       # all the steps
```

Any GNU make 4.3 or later works. CI uses the make of cosmocc, so the
build does not depend on the make of the host.

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
| `nifs` | `sqlite` | Builds the NIFs of exqlite, bcrypt_elixir and argon2_elixir, except those of `NIFS_OMIT` (nothing with `ELIXIR=0`). |
| `wasm` | `configure` | Builds WAMR (the interpreter and the AOT loader), the wasm NIF and the loader of NIF libraries in WebAssembly ([`NIFS.md`](NIFS.md)) (nothing with `WASM=0`). |
| `make` | `nifs`, `wasm` | Builds a small OTP: the emulator and the OTP applications. |
| `elixir` | `make` | Downloads and builds Elixir (nothing with `ELIXIR=0`). |
| `release` | `elixir` | Installs an OTP release tree, for its boot scripts. |
| `multicall` | `release` | Links the emulator again with the helper programs (`erl_child_setup`, `inet_gethost`, `epmd`, the file watcher) and the static NIFs. |
| `wasm_runtime` | `multicall` | Builds the WebAssembly runtime with Emscripten (`wasm/erts/build.sh`). |
| `bundle` | `wasm_runtime` | Writes `build/beam.com`: the emulator and its zip. |
| `test` | `bundle` | Runs `beam.com`, and builds and runs a program with it. |
| `unit` | `bundle` | Runs the tests of the Mix project with the `beam.com` of the build (`beam.com mix test --cover`). |

`make STEP` runs the step and each step that it needs first. A step runs
again only when its key changed, or when a step that it needs ran again
(see [The keys of the steps](#the-keys-of-the-steps)). A new time of a
file, as in a new checkout, does not run a step again.

`test` and `unit` run each time. `make redo-STEP` runs a step again with
no change of its inputs. The steps run one at a time, because they share
the OTP tree. Each step uses `JOBS` processes. With `CCACHE=1`, the
compiles of cosmocc and cosmoc++ go through ccache, in `build/ccache`
(`CCACHE_DIR`). It is not a setting: the file is the same.

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
or rebar3. A custom build can have more, or less:

- `OTP_APPS="mnesia eldap"`: more OTP applications in the zip (their Erlang
  code; the C code of an application, as the port programs of `os_mon`,
  is not built).
- `OTP_OMIT="ssh xmerl"`: default OTP applications to leave out of the
  zip, for a smaller file. Only `parsetools`, `asn1`, `public_key`,
  `ssl`, `inets`, `ssh`, `xmerl`, `runtime_tools` and `tools`: beam.com
  itself needs `kernel`, `stdlib`, `sasl`, `compiler` and `crypto`. The
  build stops when an application of the zip needs an application of
  `OTP_OMIT` (`ssl` needs `public_key`, which needs `asn1`). Hex, rebar3
  and the downloads of packages need `inets` and `ssl`.
- `HEX=1`: Hex in the zip (the newest, from `mix local.hex`). The tools
  of Elixir have it in their code path, so `mix.com deps.get` needs no
  `mix local.hex`. Only with `ELIXIR=1`.
- `REBAR3=1`: rebar3 in the zip (the newest release). A copy or a link
  named `rebar3.com` (or `beam.com rebar3`) runs it, and `mix.com` uses
  it for the dependencies that are rebar3 projects (`MIX_REBAR3`), so
  `mix local.rebar` is not needed either.
- `NIFS_OMIT="bcrypt_elixir argon2_elixir"`: default NIFs to leave out,
  for a smaller file: `exqlite` (with `SQLITE=1`), `bcrypt_elixir` and
  `argon2_elixir`. `beam.com --version` names only the NIFs that the file
  links. A project that uses a package of a NIF that the file does not
  link must build that NIF itself (`make` and a C compiler). In the
  builder, the default NIFs are checked boxes, as the default OTP
  applications are.
- `EXTRA_NIFS="picosat_elixir"`: the NIFs of more hex.pm packages,
  linked as those of `bcrypt_elixir` and `argon2_elixir` are (see
  "Phoenix from source" in [`ELIXIR.md`](ELIXIR.md)). The list is in
  `hex_nif_recipe()` of `scripts/steps.sh`: `picosat_elixir` (the SAT solver of
  Ash), `vix` (libvips, for the `image` package), `rusty_csv` (CSV, a
  NIF of Rust) and `ex_pdfium` (PDF documents with PDFium, a NIF of
  Rust). Only with `ELIXIR=1`.
  - `vix` needs a static libvips for each CPU. `scripts/libvips.sh`
    builds it in `build/libvips` (meson, ninja, cmake, nasm and pkg-config),
    or `LIBVIPS` names a build that exists. It builds in two stages:
    1. The libraries that libvips needs, with those of each part, in
       `build/libvips-deps` (`DEPS`): about 10 minutes with 4 CPUs, one
       time. The script keeps them while the SHA-256 of their recipe
       (`scripts/libvips.sh --deps-key`) is the same.
    2. libvips with the parts of `VIX_PARTS`, on a copy of these
       libraries: about 1.5 minutes.
    It has the libraries of sharp-libvips, with the formats JPEG, PNG,
    WebP, GIF load and PPM, and the SIMD code of zlib-ng, libjpeg-turbo,
    libwebp and Highway. The times of `tests/programs/vix_check` are near
    those of the precompiled vix. The file is about 13 MB larger (about
    6 MB with gzip).
  - `VIX_PARTS` adds parts to the libvips of `vix`, separated by spaces.
    In the builder, these are the choices `vix-icc`, `vix-gif`,
    `vix-avif` and `vix-svg` under `vix`:

    | Part | For | Libraries | More size |
    |---|---|---|---|
    | `icc` | ICC transforms | lcms2 | under 1 MB |
    | `gif` | GIF save | cgif, and libimagequant for the palette | under 1 MB |
    | `avif` | AVIF read and write | libheif with aom, `MinSizeRel` as in sharp-libvips | about 12 MB (5 MB with gzip) |
    | `svg` | SVG and SVGZ load | resvg (Rust, `native/vips_resvg`), not librsvg | about 5.5 MB (2.7 MB with gzip) |

    aom and libheif of `avif` are about 6 of the 10 minutes of the
    libraries. An AVIF encode of 1 megapixel takes about 1.7 s on 4
    CPUs. `scripts/libvips.sh` writes the parts in `build/libvips/parts`,
    and a build with other parts builds only libvips again. There is no
    text operation (pango).
  - `svg` puts `c_src/vips/resvgload.c` in the place of the loader of
    librsvg. It has the same names (`svgload`, `svgload_buffer` and
    `svgload_source`) and the same arguments. resvg draws the text of an
    SVG with the fonts of the system: the folders of fontconfig on Linux,
    and the font folders of macOS and Windows. With no fonts, the text
    is not drawn. `build_rust_nif` builds the crate (it needs rustup).
    The differences from librsvg:
    - The loader draws the whole image in memory in one step, not in
      tiles.
    - The output has 8 bits for each band. `high_bitdepth` gives a
      warning.
    - The SVG gets only the images of `data:` URLs. It never reads a
      file or the network, so an SVG from a user cannot read the files
      of the server.
  - The NIF of `vix` is native only: the WebAssembly runtime has no
    threads, and libvips needs them.
  - `rusty_csv` is a NIF of Rust (Rustler). `build_rust_nif` builds the
    crate as a staticlib for each CPU, with the Rust toolchain of its
    `rust-toolchain.toml`, which `rustup` installs (with rust-src, for the
    aarch64 std: see C41 to C43 in [`UPSTREAM.md`](UPSTREAM.md)), and with
    LTO. cargo downloads the crates of its `Cargo.lock`. The file is about
    1.3 MB larger (about 0.7 MB with gzip). `mix.com` and `beam.com DIR -o
    OUT` compile the package with no cargo and no download (R2 to R4 in
    `UPSTREAM.md`). On Linux x86_64, the times of
    `tests/programs/rusty_csv_check` are about 1.15 times those of the
    precompiled NIF. Its parse of 10 MB takes about 1/19 of the time of
    NimbleCSV. The NIF is native only.
  - `ex_pdfium` is a NIF of Rust with PDFium (pdfium-render with its
    feature `static`). `scripts/pdfium.sh` builds a static `libpdfium.a`
    for each CPU with cosmocc. It checks out PDFium `chromium/7881` (the
    version of pdfium-render 0.9.3) with depot_tools (about 2 GB), applies
    `patches/pdfium` (P1 to P4 in [`UPSTREAM.md`](UPSTREAM.md)), and builds
    it with GCC and the C++ library of cosmocc. It has no V8, no XFA and
    no stack protector. The build takes about 5 to 10 minutes for each
    CPU, and `PDFIUM` names a build that exists. The crate has no
    `rust-toolchain.toml`, so it builds with `RUST_NIGHTLY`. The file is
    about 18.7 MB larger. It has the license texts of PDFium and of its
    third-party code in `licenses/pdfium`.
    `tests/programs/ex_pdfium_check` checks the NIF on each system
    ([`pdfium.yml`](../.github/workflows/pdfium.yml)). Its times are near
    those of the precompiled NIF (see "ex_pdfium" in
    [`BENCHMARKS.md`](BENCHMARKS.md)). The NIF is native only.
  - A package with a NIF of Rust that the file does not link stops the
    compilation of the project, with the NIFs of Rust of the file in the
    error. With `BEAM_COM_UNLINKED_NIFS=stub` at compile time, its module
    compiles with no NIF, and each function of the NIF fails at its first
    call (`:nif_not_loaded`). The rest of the app works.
  - A project with the package `rustler` in its deps uses that package
    in place of the module `Rustler` of beam.com. `use Rustler` reads
    `skip_compilation?` with `Application.compile_env/3`, so the config
    of the project must set it for each linked crate, for example
    `config :rusty_csv, RustyCSV.Native, skip_compilation?: true`. Else a
    release stops at boot.

- `OTP_VERSION=29.1.2 OTP_COMMIT=...` and `ELIXIR_VERSION=1.20.5
  ELIXIR_COMMIT=...`: other versions of Erlang/OTP and Elixir. The commit
  of the tag is necessary, because a tag can move. The patches of
  `patches/otp` apply to OTP 29.0 and later, not to OTP 28. Elixir 1.19
  does not support OTP 29. `OTP_VERSIONS` and `ELIXIR_VERSIONS` of
  [`scripts/custom_build.py`](../scripts/custom_build.py) give the
  versions of the forms, with their commits. The workflow
  [`custom-build-versions.yml`](../.github/workflows/custom-build-versions.yml)
  builds and tests each pair of these versions. Add a version to a table
  only after that workflow passes.

With `HEX=1 REBAR3=1`, a clone of a project, `mix.com deps.get` and
`iex.com -S mix phx.server` work as with a normal Elixir installation.

You do not need to build it yourself: open an issue with the form **A
custom build of beam.com**. CI builds the file with your choices
([the workflow](../.github/workflows/custom-build.yml)), puts it on the
issue (a download of the run, with a GitHub account, for 90 days), and
closes the issue. A custom build has the WebAssembly runtime too
(`--target wasm32`), and CI builds and runs a program with it before the
answer. It is built from `main`, and the answer names the commit.

Without a GitHub account, use the form of
[mkfifo.com/beam.com](https://mkfifo.com/beam.com). It sends a
link with a one-time code to your email address, and the link starts the
same workflow. A second email gives the link of the file, or the reason
when the build did not run. The file stays in the prerelease
`custom-builds` for 30 days, and the FIFO streams it.

- The form is a held FIFO of [mkfifo.com](https://mkfifo.com/): its
  envelopes are in [`priv/seeds/beam.com/`](../priv/seeds/beam.com).
  [`scripts/beam-fifo.py`](../scripts/beam-fifo.py) saves them in
  the holder, with the secrets of the environment (see its help).
- The FIFO and the workflow accept only the values of the issue form
  ([`scripts/custom_build.py`](../scripts/custom_build.py)). The form
  has a box for each default OTP application that a build can leave out,
  checked, a box for each known OTP application to add, and a list of
  the versions of Erlang/OTP and of Elixir.
- The page has no script (the CSP of the FIFO lets in only inline
  styles). Rules of CSS with `:has()` do the work of a script. Without
  Elixir, the form hides the Elixir version, Hex and the NIFs, and the
  build ignores them. A choice that the build refuses, as `ssl` without
  `public_key`, shows a warning and turns off the button. The workflow
  checks each rule again, because a request can come without the page. The workflow
  refuses a request that leaves out an application that another one
  needs, before the build, and the email gives the reason.
- One build runs at a time, in the sequence of the requests. At most 3
  requests wait, and at most 10 new builds are made each day (UTC).
- Two requests with the same choices get the same file: the second one
  gets the link at once, with no build. The key of the file is the
  SHA-256 of the choices and of the source of the build (`source()` of
  `custom_build.py`). A commit that changes only the documents, the
  tests, the workflows or the envelopes of the FIFO keeps the key.
- A new build takes most of its work from the store of parts (see
  [The store of parts](#the-store-of-parts)): the built OTP, Elixir and
  each NIF. With each part in the store, a build takes a few minutes.
- For a part that is not in the store, a build takes these parts of it
  from the cache of GitHub Actions when their inputs did not change:
  - The WebAssembly runtime (about 3 minutes). Its key is the SHA-256 of
    its inputs (`scripts/steps.sh wasm_runtime_key`): only the code of
    `scripts/steps.sh` that its build runs, so a change of another step
    keeps it. It has the key of `build.yml`, so the builds of
    `main` fill it.
  - The libraries of libvips (about 10 minutes).
  - libpdfium.a for each CPU (about 10 minutes each).
  - The keys of libvips, libpdfium.a and ccache come from
    `sh scripts/steps.sh cache_keys`, so the workflows have no list of
    files of their own.
  - The objects of ccache (`CCACHE=1`) for each OTP version: about 4 of
    the 7 minutes of the build of OTP are C and C++ compiles. A new OTP
    version starts from the cache of an earlier version.
    `custom-build-versions.yml` fills it for each pair of versions.
  - Only a run on `main` fills a cache that a custom build can read.
    [`custom-build-caches.yml`](../.github/workflows/custom-build-caches.yml)
    builds a custom build with all the parts of `vix`, `ex_pdfium` and
    `rusty_csv`. It fills the store and these caches for the default
    versions. It runs after a merge that changes their inputs, and two
    times each week, because GitHub removes a cache that no run reads
    for 7 days.
  - A pull request only reads the caches, so its copies do not push out
    the caches of `main` from the 10 GB of the repository. The log of
    `custom-build-caches.yml` shows the use of the 10 GB and the largest
    caches.
- GitHub never sees the email address: the FIFO sends it in a box of
  `secretbox`, which only the FIFO opens.
- The workflow needs the secret `BEAM_FIFO_SECRET` of the repository:
  the FIFO accepts an answer only with it. The variable `BEAM_FIFO_URL`
  changes the address of the FIFO. The token of the workflow puts the
  files in the release, so no other key is necessary.

## The store of parts

A part is the output of some steps of `scripts/steps.sh`, which a build
can take in place of the work: `NAME-KEY.tar.xz`. KEY is the SHA-256 of
all the inputs of the part, so the same inputs give the same name, and a
part never goes stale. `PARTS_URL=... make` uses a store, and
`sh scripts/steps.sh part_keys` prints the key of each part of a build
(after the steps `otp` and `configure`).

| Part | The output of | Its key has |
|---|---|---|
| `otp` | the steps `otp`, `configure` and `make`: the built OTP tree | the versions of OTP, OpenSSL and cosmocc, `CC`, `CXX`, `AR`, `JIT`, `CCACHE`, the path of the tree, the applications (`SRC_APPS`), the code of these steps, `patches/otp`, `erts_cosmo.h`, `noshared` and `depcc` |
| `elixir` | the step `elixir` | the version of Elixir, `patches/elixir`, the code of the step, and the key of `otp` |
| `nif-PACKAGE` | one NIF of the step `nifs`: `LIB.a` and `.aarch64/LIB.a` | the recipe of the package, the NIF API (the headers of the OTP tree), cosmocc, the code that builds it, and its files (`scripts/libvips.sh`, `patches/libvips`, `c_src/vips` and `native/vips_resvg` for vix with its parts; `scripts/pdfium.sh` and `patches/pdfium` for ex_pdfium; `c_src/rust` and `scripts/rust_link.sh` for a NIF of Rust) |

The other files of `c_src/cosmo` are not in the key of `otp`: the step
`multicall` compiles them again. A tree of the store gets one time for
all its files, so that a file that a later step writes is newer, and
make builds only what depends on it.

The settings:

- `PARTS_URL`: the address of the store, with no `/` at the end. A
  missing part is not an error: the step builds it.
- `PARTS_PUT`: an absolute directory. A step that builds a part packs it
  there.

In CI, the store is the prerelease `parts` of the repository, and
`PARTS_URL` is the address of its files.
[`custom-build.yml`](../.github/workflows/custom-build.yml) and
`custom-build-caches.yml` build with `PARTS_PUT`, and after the checks
of the file, a step with the token puts the new parts in the release.
The build itself has no token.

- Caution: a part is code that goes into the files of beam.com. Only the
  workflows of `main` put parts, never a pull request.
- Caution: a key that leaves out an input gives a part that does not
  match its inputs. The code of a key is that of its functions, as in
  the keys of the steps. A key of a part names its settings and its
  files (`nif_part_key`, `otp_part_key` and `elixir_part_key` in
  `scripts/steps.sh`): add a setting or a file that a step of a part
  starts to read.

## The keys of the steps

The key of a step is the SHA-256 of its inputs. The Makefile runs a step
again only when its key changed, or when a step that it needs ran again.
`scripts/steps.sh` finds the inputs of each step:

- The code: the function of the step, and each function that this code
  names, again and again. Comment lines are not code, so a change of a
  comment keeps the key. The functions that find keys
  (`KEY_FUNCS`) are not followed, because their code names the steps
  only to find a key.
- The settings: the value of each variable in capitals that this code
  reads. `KEY_IGNORE` lists the variables that do not change what a step
  makes, for example `JOBS`, `PATH` and `CCACHE`.
- The files: the SHA-256 of each file of its list in `step_files`, as
  the work tree has it.

Thus a change of a function of `scripts/steps.sh` runs again only the
steps that use it. For example, a change of `build_cosmo_file` runs
`multicall` and the steps after it.

The commands:

| Command | What it does |
|---|---|
| `sh scripts/steps.sh key STEP...` | Prints the key of each step. |
| `sh scripts/steps.sh inputs STEP` | Prints the inputs of a step. Compare it with `build/stamps/STEP.inputs`, the inputs of the last key, to see why a step runs again. |
| `sh scripts/steps.sh check_keys` | Finds each path of the repository in the code of a step that is not in its list of files. CI runs it. |
| `sh scripts/steps.sh cache_keys` | Prints the keys of the caches of CI (libvips, libpdfium.a and ccache). |

- Caution: a file that a step starts to read must be in its list in
  `step_files`. `check_keys` finds a path that the code writes with
  `$ROOT`, but not a file that another program reads, as the files that
  `wasm/erts/build.sh` reads.
- Caution: a setting that only a program reads, and not the code of a
  step, is not in a key. Read it in the code of the step, or run
  `make redo-STEP` after a change.

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
