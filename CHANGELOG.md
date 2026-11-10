# Changes

The release job of CI puts the section of a version at the start of the
notes of its release.

## Unreleased

- `beam.com DIR -o FILE` makes one file from a Phoenix app, with no Mix
  task first. A Mix project with `config/runtime.exs`, a dep that is not
  a Hex package (git, github, path), a dep of a Hex organization or of
  another Hex repository, `:compilers`, or the alias `assets.deploy`
  needs Mix itself. For it, a child `beam.com`
  (`beam_com_mix`) runs Mix in the project, with the environment of the
  user: `deps.get`, `compile`, `assets.deploy`, and `release` with
  `include_erts: false`. Then the builder makes the file from the
  release. The release consolidates the protocols, and the program reads
  `config/runtime.exs` at each start. When the deps need Hex, the child
  installs it, as `mix local.hex` does. `--tool mix-release` uses Mix for
  each Mix project, and `--tool mix` keeps the builder of a plain Mix
  project. See "Phoenix in one file" in `docs/ELIXIR.md`.
- `docs/DEPLOY.md`: deploy a Phoenix app to a Linux server, with a build
  on the server or in CI.
- Port programs on Windows (C16 of `docs/UPSTREAM.md`). The spawn driver
  starts the program itself with `posix_spawn()`, because
  `erl_child_setup` cannot work there. Thus `open_port/2`, `peer`,
  `System.cmd/3`, `os:cmd/1` (with the `sh` of Git for Windows in
  `PATH`), and the Mix steps of `beam.com DIR -o FILE` work on Windows.
  `os:find_executable/1` tries `.exe`, `.com`, `.cmd` and `.bat` there.
  The writes to a port program are non-blocking, as on Unix. The wraps
  of `write()`, `writev()` and `select()` (`c_src/cosmo/beam_com_pipe.c`)
  write at most the free space of a pipe. A larger non-blocking write to
  a pipe of Cosmopolitan on Windows can lose data. The wraps do not
  report a full pipe as writable. `tests/cosmo/pipe_check.c` checks
  them on Windows.
- A `chown()` to the owner and the group that a file already has gives
  0 (C28): `File.cp/3` copies the owner, and it failed on Windows.
- On Windows, a script with `#!` runs as a port program: with the
  `escript` of `beam.com` for an escript (such as `rebar3`), else with
  the `sh` in `PATH`.
- On Windows, a Phoenix build gets the tailwind and esbuild programs for
  Windows, when the config gives no target and no path for them, and
  `mix.exs` has the alias `assets.deploy`. The builder checks the
  signature of npm and the SHA-512 of the esbuild package, as the esbuild
  package of Hex does.
- On Windows, the git client uses the SSH agent of Windows OpenSSH
  (`\\.\pipe\openssh-ssh-agent`) when `SSH_AUTH_SOCK` is not set. The
  helper program `ssh_agent_bridge` connects to the named pipe (C55).
- CI builds a new Phoenix app on Windows with `beam.com . -o FILE`, and
  gets the start page and the digested CSS of the file. It also checks
  the SSH agent of Windows OpenSSH.
- `tests/run.ps1` needs PowerShell 7.3 or later. It stops each process
  that a check started and that still runs, and it removes the key and
  puts back the service `ssh-agent` at the end of its check. In CI, a
  check that cannot run is a failed check. Both scripts install the
  fixed `phx_new` 1.8.16.
- On Windows, a relative symbolic link to a directory works (C54). Before,
  `mix release` copied no `priv` of the app, because `stat()` of the
  link `_build/prod/lib/APP/priv` gave `EACCES`.
- `beam.com DIR -o FILE` over the file of a program that runs updates it:
  the builder writes a new file and renames it, and the program loads the
  changed code. The builder strips the beams of the program and of its
  deps, as `mix release` does, and compiles with `deterministic`. Thus
  two builds of the same code almost always give the same bytes, and the
  new file has only the changed modules. A file that a Mix step writes
  with a new time (`cache_manifest.json` of `phx.digest`) is new at each
  build, and a run takes the files of `priv/` that the build wrote from
  after the build, so it does not build again. The reload
  gives no notice for a new file of `.wasm/`.
- With no `git` program, the git deps of an `https` URL come with the git
  client of beam.com (`beam_com_git`, `beam_com_git_scm`): version 2 of
  the git protocol over HTTPS, the commit of `mix.lock` with depth 1, and
  the name of each object computed from its data. `mix.lock` stays the
  same as with git.
- The git client of beam.com also speaks SSH (`beam_com_git_ssh`), with
  the `ssh` application of OTP and no `ssh` program. It takes
  `git@host:path` and `ssh://` URLs, and it reads `~/.ssh/config`
  (`Host`, `Include`, `HostName`, `User`, `Port`, `IdentityFile`,
  `IdentitiesOnly`, `IdentityAgent`, and more). It uses the keys of the
  SSH agent and of `~/.ssh`. It checks the host key in `known_hosts`:
  an unknown host stops the build, with its fingerprint. It uses version 2 of the git protocol, else version 0.
  `BEAM_COM_GIT=client` uses the client also when `git` is in `PATH`.
  See "Git over SSH" in `docs/PROGRAMS.md`.
- The builder of a rebar3 project gets the git deps of `rebar.config`
  (`git` and `git_subdir`, of an `https` or SSH URL) with the same git client,
  and their deps. `rebar.lock` keeps the commit of each git dep, as
  rebar3 does. See "Git deps" in `docs/PROGRAMS.md`.
- The builder reads a map in a term of a package, for example `#{}` as
  the requirements of `metadata.config`. Before, the build of a package
  with a map stopped with "metadata.config is not a list of terms".
- `erlang:system_info(system_architecture)` gives the CPU and the system
  where the file runs, for example `aarch64-unknown-linux-gnu` or
  `aarch64-apple-darwin`. Before, it was `x86_64-pc-linux-gnu` on each
  CPU and each system, and the tailwind and esbuild packages of Phoenix
  downloaded x86_64 programs on Linux aarch64 (O28 of
  `docs/UPSTREAM.md`).
- The builder of a plain Mix project compiles a package after its
  optional deps that the build has, as Mix does. Before, `ecto_sql`
  could compile before `postgrex`, and the program stopped at its start:
  "could not find Ecto.Adapters.Postgres.Connection".
- With a `mix.lock` that Mix wrote, the builder takes only the entries
  that the deps of the program reach. Before, it also compiled the deps
  only for `:dev` or `:test` of the lock, such as `phoenix_live_reload`.
- A program loads new code when a new file takes the place of its file,
  so a deploy can send only the changed code: `zip -r app.com
  lib/my_app-0.1.0` on the server. The process `beam_com_reload`
  (`src/beam_com_reload`, in each program, with no change of OTP):
  - loads each module whose code changed, together, from the code path
    only, and waits when a process still runs old code;
  - does the `update` instructions of a new appup, with `code_change/3`,
    and starts the new children of a supervisor after its update;
  - for new files of `priv/`, moves the application to a copy in the
    cache, and calls its `config_change/3` (the static manifest of a
    Phoenix endpoint). The copy before goes 60 seconds later, and the
    first check removes the copies of processes that do not run.
  - adds no time to the start of a program: the start does only a stat
    and an open of the file.

  The processes and their state stay. A new runtime needs a restart.
  `BEAM_COM_RELOAD=MS` sets the time between two checks, and
  `BEAM_COM_RELOAD=0` turns it off. Not on Windows. See "New code in a
  running program" in `docs/PROGRAMS.md`, and `examples/reload`.
- A push that changes the source of a build does not delete the files of
  the build URLs. The job `urls` of `custom-build-caches.yml` builds
  each URL again whose key changed, and the new file replaces the old one
  when it is ready. Thus a request, for example of CI, gets the old file
  at once and never waits. Before, a push deleted each file, also a push
  that did not change a build, and the next request waited for a new
  build. Each file of a URL now has `NAME.json`, with the key of its
  build and its query. A change of only `scripts/custom_build.py` keeps
  the key when the settings do not change. `custom-build-caches.yml`
  runs after each push that changes the source of a build, and each day.
- Each new custom build also goes to the prerelease of its month,
  `kept-YYYYMM`, as `beam-SHA256.com`, and no job deletes it. A lock
  names this URL and the SHA-256, so a new build of the same build URL
  does not break the lock. `NAME.json` of each file gives the kept URL.
  See "A fixed version of a build" in `docs/BUILDING.md`.
- Each new custom build has `NAME.sha256` next to it in the release
  `custom-builds`, and an attestation of `custom-build.yml`. A separate
  job signs the file, so the code of a build cannot sign. See "A fixed
  version of a build" in `docs/BUILDING.md`.
- A query of only `nifs+=` or `nifs=` that needs a build also gets
  `503` with `Retry-After: 15` at once, and a browser gets the page that
  loads again (the envelopes `35-url-not-yet` and `36-url-page`). Before,
  it waited in the VM, and on Cloudflare it got `504` after 60 seconds,
  or `404` for a refused build, which stops `curl --retry`.
- A query of a build that is not ready gets `503` with `Retry-After: 15`
  at once, and does not wait for the build. `curl --retry` asks again,
  and a browser gets a page that loads again each 15 seconds and then
  starts the download. A refused build gives `422` with the reason.
  Before, the request waited, and on Cloudflare it got `504` after 60
  seconds (the envelopes `32-query-refused`, `33-query-not-yet` and
  `34-query-page` of the FIFO beam.com).
- A build URL waits, and does not fail at once with 404, when a check of
  the release gets another status than 2xx or 404 from GitHub for a
  moment (the new envelope `31-u-not-yet` of the FIFO beam.com).
- The publish of `edge` keeps the old `beam.com` until the new one is in
  the release (`scripts/publish_edge.sh`). Before, the job deleted the
  release first, and a failed upload left `edge` with no file.
- `curl -fo beam.com https://mkfifo.com/beam.com` gives the default
  build (the `edge` file) at once. A browser gets the form, now at
  `https://mkfifo.com/beam.com?form`.
- Each choice of a custom build is a field of the query of the build
  URL: `otp_version`, `elixir_version`, `apps`, `omit`, `hex`, `rebar3`,
  `jit`, `sqlite`, `wasm`, and `nifs+` or `nifs`. For example
  `?otp_version=29.1.2&apps=mnesia&nifs+=vix`. The request waits for the
  build. The form sends a `GET` with its fields (Download), so its
  download URL also works with `curl`; "Send me the link" stays. See "A
  build URL" in `docs/BUILDING.md`.
- Native NIF objects (`docs/NIFS.md`): `erlang:load_nif(PATH, Info)`
  loads `PATH.x86_64.o` or `PATH.aarch64.o` from the zip of the program,
  before a NIF in WebAssembly. The object is the NIF as `cosmocc -c`
  compiles it (and `ld -r` joins it), with no change to its C code. It
  runs at the speed of native code, on each system of the CPU. The
  object can call each `enif_*` function and the functions of the libc
  in `c_src/cosmo/beam_com_nif_libc.h`. Thread-local data works, with
  each TLS model of C (cosmocc) and of Rust: the NIF of `rusty_csv` loads
  as an object. C++ works: the object links the members of libc++ that it
  needs, and the program gives libc++abi; the NIF of `ex_pdfium` (PDFium)
  loads as an object. The loader removes the sections that the NIF does
  not use, as `ld --gc-sections` does, and reads an object with more than
  65,279 sections. `tests/programs/native_nif_check` runs on each system
  in `tests/run.sh`.
- The NIF of `vix` (libvips, glib, and the AVIF, GIF, ICC and SVG parts)
  loads as a native NIF object. `scripts/nif_object.sh` makes the objects
  of a NIF part of the store. `tests/programs/store_nif_check` runs vix,
  rusty_csv and ex_pdfium as objects on each system of CI. The libc of
  the objects has 253 more names (about 0.5 MB in `beam.com`).
- `BEAM_COM_NIF_MAP=FILE`: the loader writes the address and the name of
  each function of a native NIF object.
- macOS arm64: the TLS of Rust in a native NIF object used `tpidr_el0`,
  which is not the thread pointer of Cosmopolitan on XNU (the SVG part of
  vix crashed). The loader changes each `mrs xN, tpidr_el0` of an object
  to `mov xN, x28`. The aarch64 test objects now keep this instruction,
  as the code of Rust does.
- The NIF files of `beam.com` (`lib/beam_com/priv/nifs/APP-VSN`): a
  package gets the native NIF objects of its directory in its priv
  directory, in `beam.com DIR -o OUT`, in `make` of `elixir_make`, and in
  the module `Rustler` of `beam.com`. The list of these packages comes
  from the directory, so a `beam.com` assembled with more files needs no
  other build: it builds the projects of vix, rusty_csv and ex_pdfium
  from hex.pm with no static NIF of them. `beam.com --version` names
  them ("NIF files").
- The entry of a native NIF object can be its one global function
  `NAME_nif_init`: Rustler loads `priv/native/libCRATE`.
- `tests/cosmo/nif_needs.c`: each name that a native NIF object needs
  and that the program does not have, in one run. CI checks the objects
  of the store with it.
- An assembled `beam.com` has the license texts of its NIF parts
  (`licenses/pdfium` for ex_pdfium), as the static build has them, and
  each program of it keeps them.
- `beam.com DIR -o OUT` writes `mix.lock` as Mix writes it: the keys are
  atoms, and each entry has the optional deps too. Before, a later
  `mix deps.get` stopped: Hex read a name with `atom_to_binary/1`, and
  checked the deps against the registry.
- `scripts/assemble.erl`: a program and new files in its zip, as a server
  can stream it: the bytes of the program up to its central directory,
  the new entries, and a new central directory. The length is known
  before the first byte. The tests run `store_nif_check` assembled in
  this way on each system.
- `beam.com --nif-include`: the headers also work for a native NIF object
  of `cosmocc`, on x86_64 and aarch64.
- `scripts/assemble.erl --parts` cuts the programs of each set of NIF
  packages into segments: the bytes of the program up to its central
  directory, the entries of each package, and one central directory for
  each set. The segments of a set, one after the other, are the program.
  A spec `PREFIX/=DIR` adds each file of a directory.
- A build URL of `nifs+=` with only vix, rusty_csv, ex_pdfium and the
  default NIFs gets its program at once, with no build: the FIFO
  beam.com streams the segments of the `edge` program and the NIF
  objects. The job `edge-parts` puts them in the prerelease
  `program-parts` after each publish of `edge`. This answer has no
  `Content-Length`. See "A build URL" in `docs/BUILDING.md`.
- A build URL: `curl -fo beam.com 'https://mkfifo.com/beam.com?nifs+=rusty_csv'`
  gives a custom build with the default NIFs and rusty_csv, and
  `?nifs=rusty_csv` gives only rusty_csv. The answer is the file as a
  stream. When the file is not there yet, the request waits for its
  build (about 2 to 3 minutes), with no email and no form. See "A build
  URL" in `docs/BUILDING.md`.
- macOS arm64: about 1 start in 300 of a program with a sandbox hung
  before ERTS started, with the CPU in use (#177). The APE loader mapped
  the program over regions of the malloc zone of libSystem, so a call of
  libSystem (`sandbox_init()`, `os_log()`) wrote over the data of the
  program. `patches/cosmo/ape-m1.patch` makes the loader check that the
  fixed addresses of the program are free, and start again when they
  are not (C51 of `docs/UPSTREAM.md`). On a Mac that has the loader of an
  older APE file in `$TMPDIR/.ape-1.10` or `~/.ape-1.10`, remove it, so
  that the shell header compiles the new loader.
- The workflow "Remote SSH" makes the downloaded `beam.com` executable.
  The shell header of an APE file starts with `command -v "$0"`, and the
  `/bin/sh` of macOS (bash) gives nothing for a file that is not
  executable. So the server did not start on macOS, with "gzip: (stdin):
  unexpected end of file".

- Security: on Linux, each sandbox let the program delete each file and
  each empty directory of its user, also with `--allow-read` only. The
  `unveil()` of Cosmopolitan did not give Landlock the rights of removal
  (C50 of `docs/UPSTREAM.md`). Now a removal needs a path of
  `--allow-write`, as the other changes do, and a rename from outside
  the rules gives `eacces`.
- On Linux, a program with `--allow-run` could not start its own file
  in erl mode (for example with `peer`): the new VM printed "the kernel
  has no Landlock" and stopped with the exit status 127. The `pledge()`
  of the program refused the system calls of Landlock, so the new VM
  could not make its own sandbox. Now the program has the promise
  `unveil` with `--allow-run`. A new Landlock ruleset only removes
  rights, so the new VM can do no more than the program. On macOS
  arm64, the new VM stopped too, because Seatbelt refuses a second
  `sandbox_init()`. Now the program keeps the digest of its file and
  its permissions in `BEAM_COM_SEATBELT`, and a new VM with the same
  file and permissions goes on in the profile of its parent. `tests/sandbox_claims.txt` checks it
  (`sandbox_check erl PATH`).
- Security: on Linux with a kernel that has no Landlock, `--allow-run`
  with a list let the program start each program as a port. Now
  `erl_child_setup` checks the real path of each program, and of the
  shell of `{spawn, Command}`, against the paths that Landlock gives
  "x": the programs of the list, the directories of the libraries, the
  file of the program and its APE loader. Another program gives
  `eacces`, as with Landlock. The CI job below found it.
- CI runs `tests/run.sh` on Linux with a kernel that has no Landlock
  (#171): the kernel of the runner in a VM of QEMU (virtme-ng), with
  `lsm=` and no `landlock`. `tests/sandbox_claims.txt` has a column for
  it. There, a refused socket of IPv4 or IPv6 gives `eacces`, as on
  Windows, and `docs/SANDBOX.md` says it now.
- `tests/sandbox_claims.txt`: each claim of `docs/SANDBOX.md` as a test,
  with the expected result on Linux, macOS arm64, Windows, OpenBSD and
  the systems with no sandbox. `tests/run.sh` and `tests/run.ps1` run it
  in CI. `sandbox_check` has more actions for it (`mkdir`, `rmdir`,
  `delete`, `rename`, `symlink`, `stat`, `list`, `readn` and
  `unixconnect`).

- `wasm_host:memory(used)` gives the memory that the VM uses now in the
  WebAssembly runtime: the bytes that `malloc()` gives out. It goes down
  when the VM frees memory, also with `-Mea min`. `wasm_host:memory/0`
  (the size, which never shrinks) is also `wasm_host:memory(size)`
  (#166).
- The WebAssembly runtime has no cache of segments of ERTS by default
  (`+MMmcs 0`). The cache kept freed carriers from `malloc()`, so a heap
  that shrinks grew the memory of the VM by up to 32 MB, in steps of 8
  MB. With no cache, the peak of `tests/wasm_diff/mem_check.erl` went
  from 162 MB to 74 MB, and each of its cases is flat. The test now also
  checks `wasm_host:memory(used)`.
- `docs/WORKERS.md` tells what a deploy does to a Durable Object that
  runs: it keeps its VM and the old code for up to 300 s by default, and
  `--durable-objects-code-update-mode immediate` resets it at once
  (#165). The line `beam: ready in ...` of the log has the version of the
  deploy (`BEAM_VERSION`).
- `docs/WORKERS.md` tells how Cloudflare counts the 128 MB of an isolate,
  and which value an app or a load test compares with it (#167).

- The Makefile runs a step again when its key changed, not when a file
  is newer (`docs/BUILDING.md`, "The keys of the steps"). The key of a
  step is the SHA-256 of its code in `scripts/steps.sh`, with each
  function that it calls, of the settings that this code reads, and of
  its files. So a change of `scripts/steps.sh` runs again only the
  steps that use the changed code, and a new checkout runs no step
  again. The list of settings of the Makefile is gone.
- The keys of the parts follow the functions that their steps call, in
  place of a list of names. The key of the WebAssembly runtime follows
  them too. Each key is new, so the store builds each part one time.
- The workflows take the keys of the caches of libvips, libpdfium.a and
  ccache from `sh scripts/steps.sh cache_keys`, in place of their own
  lists of files. `build.yml` runs `sh scripts/steps.sh check_keys`,
  which finds a file in the code of a step that is not in the list of
  the step.
- The step `bundle` runs again after a change of
  `c_src/wasm/include/erl_int_sizes_config.h`, and the step `multicall`
  after a change of `patches/cosmo/`. The step `nifs` runs again after a
  change of the files of libvips, PDFium or the NIFs of Rust. Before,
  the Makefile did not list these files.

- A store of prebuilt parts for the custom builds (`docs/BUILDING.md`,
  "The store of parts"): the built OTP, Elixir and each NIF, as files
  of the prerelease `parts` whose names have the SHA-256 of their
  inputs. A custom build takes each part from it, and puts each new
  part there. A part does not expire, as a cache does. Here, a build
  of `beam.com` with each part in a local store took 39 s.
- The license texts of PDFium come from the part of ex_pdfium
  (`hexnifs/static/licenses-pdfium`).
- The sandbox of Linux (#172):
  - `--allow-net` allows Unix sockets, as on macOS, for example
    `NOTIFY_SOCKET` of systemd and the socket of PostgreSQL. Before, each
    Unix socket gave `{error, eperm}`.
  - `--allow-write` allows `file:change_mode/2`, `file:change_time/2`,
    and so `File.cp/2` and `File.touch/1`. They first call `chown()`
    with no change of the owner, which the sandbox refused. That call
    now gives the result of `stat()` on each system, not only on
    Windows.
- On Linux, when the kernel has no Landlock (#171), for example in Apple
  `container`, the paths of a sandbox had no limit, with no message.
  beam.com now checks the paths in the calls of the C library there, as
  on Windows, and prints a warning: that check is weaker than Landlock.
  With `BEAM_COM_VERBOSE=1`, the program prints the ABI version of
  Landlock.
- The caches of the custom builds are full on `main`
  (`custom-build-caches.yml`). The first custom build after a change
  took about 30 minutes, because only a run on `main` fills a cache that
  it reads, and `vix.yml` runs on pull requests. The new workflow fills
  the libraries of libvips, libvips, ccache, libpdfium.a and the
  WebAssembly runtime after each change of their inputs, and reads them
  two times each week, so GitHub does not remove them.
- The cache key of libvips in `custom-build.yml` has `c_src/vips/`, as
  in `vix.yml`. Before, a change of the SVG loader kept an old libvips.
- The cache of `deps` and `_build` of `pages-app.yml` has the versions
  of `beam.com` in its key, not the SHA-256 of the file. Each run saved
  a new cache of about 180 MB, and 32 of them used 5.8 GB of the 10 GB.
- A pull request only reads the caches of GitHub Actions. Before, each
  pull request saved its own copy of a cache that it changed, and these
  copies pushed out the caches of `main` (GitHub keeps 10 GB of caches
  for each repository). A custom build then started cold: a build on
  2026-11-03 built libpdfium.a again (21 minutes). Only the WebAssembly
  runtime of `build.yml` still saves in a pull request, because the job
  `unit` of the same run reads it.
- The APE file starts under Rosetta of Apple (a Linux container of
  `container --arch amd64`). The APE loader of x86_64 crashed there
  before the program started, because its code segment could be
  executed but not read (C49 in docs/UPSTREAM.md). The build now marks
  the segments of the loader readable. Remove an old `~/.ape-1.10` once.
- The sandbox on macOS arm64: `--allow-read`, `--allow-write`,
  `--allow-net` and `--allow-run` now give a profile of Seatbelt, the
  sandbox of macOS, with the rules of Linux (docs/SANDBOX.md, "macOS").
  A refused call gives `{error, eperm}`. Before, macOS ignored the flags.
- The sandbox on Windows: `--allow-read` and `--allow-write` now limit
  the paths of the calls of the C library (`{error, eacces}` for
  another path), without `--allow-net` a socket of IPv4 or IPv6 gives
  `{error, eacces}`, and without `--allow-run` a job object of one
  process stops each new process (docs/SANDBOX.md, "Windows"). Before,
  Windows ignored the flags.
- The sandbox: on Linux 5.6 and later, a supervisor process checks the
  calls of the network of a program with `--allow-net=HOST,...`, with
  seccomp user notification. The host list then also holds for native
  code and for the programs of `--allow-run` (with their DNS queries to
  the name servers of the system). The supervisor is the parent process,
  and it gives its signals to the program. Without the features, the C
  library does the check, as before.
- The build gives a warning for `--allow-net=*.DOMAIN` when other owners
  can have names under `DOMAIN`: `DOMAIN` is in the Public Suffix List
  (`*.github.io`, `*.co.uk`), or a name of the list is under it
  (`*.amazonaws.com`). beam.com has a copy of the list
  (`priv/public_suffix_list.dat`, Mozilla Public License 2.0).
- The sandbox: `--allow-net=HOST,...` allows the network only for a list
  of hosts: names, `*.DOMAIN`, and addresses, each with an optional port
  (docs/SANDBOX.md, "A list of hosts"). beam.com has its own resolver of
  DNS: kernel asks only it, a name that the list does not allow gives
  `nxdomain` and never goes to a name server, and each connect, UDP send
  and bind gets only the addresses of the answers of allowed names
  (`{error, eacces}` for another). On Linux 6.7 and later, Landlock also
  limits the TCP ports. The list works on each system, also where the
  other permissions do nothing. It needs
  `patches/otp/0004-sandbox-resolver.patch`.
- The sandbox: on Linux, `--allow-net` now allows the options `sndbuf`,
  `recbuf` and `linger` of `inet:setopts/2`, and these options and
  `nodelay` of `inet:getopts/2` (#157). Before, `inet:getopts/2` left
  them out, so Postgrex (Ecto) and Mint (Req, Finch) could not connect.
  beam.com links a patched `pledge()` of Cosmopolitan
  (`patches/cosmo/pledge-linux.patch`).
- Faster custom builds (`custom-build.yml`), with three caches:
  - The cache key of the WebAssembly runtime is the SHA-256 of its
    inputs (`scripts/steps.sh wasm_runtime_key`). Only the functions of
    `scripts/steps.sh` that its build runs are in it, so a change of
    another step no longer builds the runtime again (about 3 minutes).
  - `scripts/libvips.sh` builds the libraries of libvips, with those of
    each part, in `build/libvips-deps`, with their own cache. A new set
    of parts of `vix` builds only libvips (about 1.5 minutes, in place of
    5 to 12).
  - `CCACHE=1` of `scripts/steps.sh` puts the compiles of cosmocc through
    ccache, with one cache for each OTP version.
- The static libvips of `vix` can have the part `svg`, with `VIX_PARTS`
  or the choice `vix-svg` of the builder (#153). It loads SVG and SVGZ
  with resvg 0.48.1, a library of Rust, in place of librsvg, so it needs
  no cairo or pango. The loader has the names and the arguments of the
  loader of libvips. Text uses the fonts of the system. The SVG gets
  only the images of `data:` URLs, and never a file. About 5.5 MB more.
- The builder: the default NIFs (exqlite, bcrypt_elixir and argon2_elixir)
  are checked boxes with the tag "default", as the default OTP
  applications are. A box that you clear leaves out that NIF, for a
  smaller file (`NIFS_OMIT` of `scripts/steps.sh`). In an issue, the list
  is "Leave out default NIFs".
- The builder: one list for Elixir, with "None" for a file with no
  Elixir, and the versions. The workflow still takes the input `elixir`
  of an older form.
- The static libvips of `vix` can have three more parts, with
  `VIX_PARTS`, or the choices `vix-icc`, `vix-gif` and `vix-avif` of the
  builder (#148):
  - `icc`: ICC transforms (lcms2 2.20).
  - `gif`: GIF save (cgif 0.5.4 with libimagequant 2.4.1).
  - `avif`: AVIF read and write (libheif 1.23.7 with aom 3.15.3), about
    12 MB more.
  These are libraries of sharp-libvips. Text (pango) is not in it.
- A thread that does not set its stack size gets 1 MB, in place of the
  80 KB of Cosmopolitan. The AVIF save of libvips stopped with SIGSEGV in
  such a thread (C46 in `docs/UPSTREAM.md`).
- The WebAssembly runtime: the memory of the VM no longer grows with each
  process that makes a big heap and then ends (issue 141). The `munmap()`
  of Emscripten frees only a whole mapping, and ERTS unmaps parts of a
  mapping to align a carrier, so most carriers never went back to
  `malloc()`. `wasm/erts/otp.patch` gives ERTS its own `mmap()` for
  Emscripten (EM9 in `docs/UPSTREAM.md`).
- `wasm_host:memory/0` gives the memory of the VM in the WebAssembly
  runtime: the size of the memory of WebAssembly, also with `-Mea min`.
- The comment and the README of `examples/phoenix_demo` said that the host
  uses `-Mea min`. The host uses the allocators of ERTS unless
  `BEAM_ERL_FLAGS` has `-Mea`.
- An x86_64 ELF file of `--target` (`x86_64-linux`, `x86_64-freebsd`)
  has its first `PT_LOAD` segment at the file offset 0. Rosetta of Apple,
  for example in a Linux container of `container --arch amd64`, refused
  the file before: `first load segment not at file offset 0` (#149).
- Each thread stack on Linux is a plain map with a guard page. Before,
  Cosmopolitan made thread stacks with `MAP_GROWSDOWN`, and under
  Rosetta the program then stopped with SIGSEGV at the start (C45 in
  `docs/UPSTREAM.md`, #149).
- A Mix release of a project with a NIF of Rust (rusty_csv, ex_pdfium)
  now boots (issue 147). `beam_com_rustler:force_build/1` set
  `force_build_all` of rustler_precompiled in the application env, and
  Elixir recorded it as a value of compile time that the release did not
  have. It now sets the environment variable
  `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL`. Compile the package again
  (`mix deps.compile rusty_csv --force`) after the update.
- `BEAM_COM_UNLINKED_NIFS=stub` (issue 146): a package with a NIF of Rust
  that the file does not link compiles with no NIF, and each function of
  the NIF fails at its first call. Without it, the compilation stops, and
  the error names the switch.

- A custom build can link the NIF of `ex_pdfium` 0.6.0 (PDF documents
  with PDFium, a NIF of Rust): `EXTRA_NIFS=ex_pdfium`, or the option in
  the issue form and the form of mkfifo.com.
  - `scripts/pdfium.sh` builds a static `libpdfium.a` for each CPU with
    cosmocc, with the patches of `patches/pdfium` and no stack protector
    (P1 to P4, C8 and C44 in `docs/UPSTREAM.md`).
  - The file is about 18.7 MB larger. It has the license texts of PDFium
    and of its third-party code in `licenses/pdfium`.
  - `tests/programs/ex_pdfium_check` passes on Linux, macOS and Windows,
    and its times are near those of the precompiled NIF
    (`docs/BENCHMARKS.md`).
  - `custom-build.yml` takes `libpdfium.a` from the cache, which
    `pdfium.yml` fills on `main`.
- `NOTICE` names the NIFs of `vix`, `rusty_csv` and `ex_pdfium`, with the
  licenses of the code that they contain.
- `build_rust_nif` builds a crate with no `rust-toolchain.toml` with
  `RUST_NIGHTLY`. Before, the step stopped with no message.

- The custom builds of mkfifo.com/beam.com and of the issue form:
  - A request can choose the version of Erlang/OTP (29.1.1, the
    default, 29.1.2 or 29.0.6) and of Elixir (1.20.4, the default, or
    1.20.5). The workflow `custom-build-versions.yml` builds and tests
    each pair. The `NOTICE` of a build names its versions.
  - The form of mkfifo.com hides the parts that need Elixir when
    Elixir is "No", and the build ignores them. A choice that the build
    refuses shows a warning, and the button is off. Rules of CSS do this,
    because the page has no script.
  - A request with the same choices gets the file of an earlier build
    also after a commit that does not change the source of the build.
    Before, the key of a file had the commit, so each commit on `main`
    made a new build.
  - A new build takes the WebAssembly runtime and the libvips of `vix`
    from the cache of GitHub Actions. This saves up to 8 of about 16
    minutes.
- `NOTICE` named OpenSSL 4.0.2, but the build uses 4.0.3. The `NOTICE`
  of the file now names the OpenSSL version of the build.

- Fixes of the custom builds of mkfifo.com/beam.com:
  - The step "Test" of the workflow now has the `CC` and `AR` of the
    build. Before, `make test` saw other settings, built again from the
    first step, and stopped at its limit of 120 s.
  - The answer of the workflow to the FIFO has its own User-Agent.
    Cloudflare refused the User-Agent of urllib (status 403), so no
    email went to the requester.
  - A request with a choice that is not possible gets the reason by
    email (the reason `choice`), and no build.

- A custom build can leave out default OTP applications, for a smaller
  file: `OTP_OMIT="ssh xmerl"`, or the boxes of the issue form and of the
  form of mkfifo.com. The form of mkfifo.com has a checked box for each
  default application that a build can leave out, and a box for each
  known OTP application to add. The workflow refuses a request that
  leaves out an application that another one needs (`ssl` needs
  `public_key`), before the build. The NIFs of Rust have their own group
  in the form. The default OTP applications of the texts now name
  `tools`, which was in the file but not in the list.

- A custom build can link the NIF of `rusty_csv` 0.4.6, the first NIF
  of Rust (Rustler) in beam.com: `EXTRA_NIFS=rusty_csv`, or the option
  in the issue form and the form of mkfifo.com. `build_rust_nif` in
  `scripts/steps.sh` builds the crate as a staticlib with the std of
  `*-unknown-linux-musl` for x86_64 and aarch64, and
  `c_src/rust/cosmo_rust.c` translates the calls of that std for
  Cosmopolitan. `mix.com` and the builder compile the package with no
  cargo and no download: beam.com has a small module `Rustler` that
  loads the linked NIF (`src/beam_com/beam_com_rustler.erl`). The NIF is
  native only. See "The steps" in `docs/BUILDING.md`, and C41 to C43 and
  R2 to R4 in `docs/UPSTREAM.md`. `tests/programs/rust_probe` and
  `tests/programs/rusty_csv_check` check it on each system
  (`.github/workflows/rust.yml`).
- The builder compiles a Mix dependency with its project on the stack of
  Mix, as Mix does: a package can read `Mix.Project.config()` when it
  compiles.

- A custom build without a GitHub account: the form of
  [mkfifo.com/beam.com](https://mkfifo.com/beam.com) sends a link
  with a one-time code to an email address, and the link starts the
  workflow of custom builds. The workflow keeps one build at a time and a
  queue of 3, makes at most 10 new builds each day, gives the file of an
  identical request at once, puts the file in the prerelease
  `custom-builds` for 30 days, and tells the FIFO, which emails the link
  and streams the file. The envelopes are in
  `priv/seeds/beam.com/`, and `scripts/beam-fifo.py` saves them.
  The choices of an issue and of the form share
  `scripts/custom_build.py`.
- A custom build can link the NIF of `vix` 0.42.0 (libvips 8.18.7), for
  the `image` package: `EXTRA_NIFS=vix`, or the option in the issue form
  of the custom builder. `scripts/libvips.sh` builds libvips and its
  libraries (glib, libffi, expat, zlib-ng, libjpeg-turbo, libpng, libwebp
  and Highway) with cosmocc for x86_64 and aarch64, with the SIMD code of
  zlib-ng, libjpeg-turbo, libwebp and Highway. The NIF is native only.
  See "The steps" in `docs/BUILDING.md`, and C38 to C40, E5, E6 and G1 in
  `docs/UPSTREAM.md`. `tests/programs/vix_check` checks it on each
  system (`.github/workflows/vix.yml`), with the times of some image
  operations.
- The builder compiles a Mix dependency into `NAME-VSN/ebin`, as Mix
  does, so `:code.priv_dir/1` finds the application while its code
  compiles. vix loads its NIF then.
- `public_key:cacerts_get/0` reads the file of `SSL_CERT_FILE` when that
  variable names a regular file, on each system. A sandbox or a proxy
  that terminates TLS (such as OpenShell) gives its CA in that file, and
  before this change Erlang clients got "unknown CA" there. Your own
  `-public_key` argument wins, and the sandbox of `--allow-net` lets the
  program read the file. See "Crypto and TLS" in `docs/INTERNALS.md` and
  "In a sandbox that terminates TLS" in `docs/PLATFORMS.md`.
- `pages-app.yml` downloads the program of Tailwind with `curl` before
  `assets.deploy`. GitHub now sends more than 10240 bytes of headers for
  the download of a release, and `httpc`, which `mix tailwind.install`
  uses, stopped with `header_too_long`.

## 0.1.0-rc.6

The sixth release candidate of 0.1.0. As 0.1.0-rc.5, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
ports to the bindings of `env`, a faster fetch path, fixes of the
WebAssembly runtime, of `gen_tcp` in the VM and of the hosts, and the
fixes from the check of 0.1.0-rc.5:

- The WebAssembly runtime can start a peer node (the `peer` module of
  OTP), on a host that gives a spawn: a port of the program of the VM
  starts a second VM, and `peer:start/1` with `connection =>
  standard_io` works with no change. The test runner of Node.js has
  such a spawn (`tests/wasm_diff/diff_peer.erl`). The Workers, Deno and
  web page hosts have no peers yet. See "Peer nodes" in
  `docs/WORKERS.md`, and EM8 in `docs/UPSTREAM.md`.
- A binding of a Worker can be a port of the VM (a spike):
  `open_port({spawn_executable, "/env/NAME"}, ...)` runs the binding
  `NAME` of `env`. The binding is a Durable Object namespace, a service
  binding to a `WorkerEntrypoint` (with no migration), or an object with
  a method `port(stdin, { argv })`, which gets the bytes of the VM as a
  stream and gives a stream of bytes back. The port program runs in
  JavaScript, in its own object, with no second VM. The flow control
  works in the two directions: the host holds at most 256 KiB of the
  bytes of a port on each side, and `Port.command/2` waits for a port
  that reads slowly. A port can give its result to the HTTP response of
  the app (`BEAM_PORT_OUTPUT=response` and the header `x-beam-port`),
  and the bytes do not go into the VM:
  on Cloudflare, 4 MiB took 13 to 33 ms of CPU time in the object of
  the VM (median 16 ms), and 47 to 71 ms through the VM (median 59 ms).
  The ports work for a VM in a Durable Object and in a plain Worker. The
  bindings are in `env` on each host: the `env` of the Worker,
  `serve(app, { env })` in Deno, and in the web page, the option `env`
  of `main.js`, the URL of a module of the site. CI tests the four hosts
  (`tests/host/app_ports.sh` and `tests/page/check.mjs --ports`), and in
  workerd both a Durable Object namespace and a service binding as ports.
  See "Ports to bindings" in `docs/WORKERS.md`.
- The front Worker serves the static files of a Phoenix app with a read
  of only their entries in `app.com`. Before, the first GET of each new
  isolate read and checked all the files of the release: for a release of
  16 MB, 100 to 180 ms of CPU time in Node.js, and 75 to 135 ms on
  Cloudflare (a report of a project). Now the read takes 2 to 3 ms. The
  VM still reads and checks all the files (`appStatics` in
  `app-com.js`).
- The lines of the memory of a VM give the count of the VMs of the
  isolate and the sum of their memories, when the isolate has more than
  one VM: `beam: memory 47 MB (a new peak of this VM; 3 VMs in this
  isolate: 130 MB)`. Cloudflare can run several Durable Objects of one
  class in one isolate, and they share its 128 MB. See "Memory and
  capacity" in `docs/WORKERS.md`.
- The process of a socket of the VM (`wasm_tcp`) hibernates after 15 s
  with no message, so an open WebSocket that waits keeps no garbage on its
  heap. Natively, the heaps of 100 sockets after some traffic went from
  2.5 MB to 0.19 MB.
- `docs/WORKERS.md` tells how to get the CPU time of the object of the VM:
  the events of `wrangler tail`.
- A crash dump no longer stops the WebAssembly runtime with "Failed to
  killing thread" and `Aborted()`. Before, each crash dump gave the exit
  status 2 and an empty `erl_crash.dump`: `erlang:halt/1` with a string,
  a boot that fails, and "Kernel pid terminated". Now the runtime writes
  the whole dump and exits with 1, as natively. The dump has no sections
  of the dirty schedulers, as on macOS. See EM7 in `docs/UPSTREAM.md`.
- A body that the program gets from `fetch()` costs much less CPU time
  at the edge. The test: in `workerd`, an app gets a body of 16 MiB from
  `fetch()` and sends it to its client. Before, each MiB used 221 to 263
  ms of CPU time. Now it uses 12 to 21 ms, and the rate went from about
  4 MiB/s to 49 to 78 MiB/s. The two causes:
  - The host read the response of `fetch()` in the pieces of `workerd`,
    4 KB each, and each piece was an event of the VM. The host now reads
    it in parts of 64 KB (a BYOB reader).
  - A scheduler of ERTS with no work spins before it sleeps, and in
    WebAssembly each yield of the spin is a JSPI suspend and a message of
    the host. The host now starts the VM with `-sbwt none -sbwtdcpu none
    -sbwtdio none`, before `BEAM_ERL_FLAGS`. The snapshot tools use the
    same flags.
- The TLS server of the fetch path in the VM chooses ChaCha20-Poly1305
  when the program offers it (the defaults of `ssl` and of Req offer
  it). WebAssembly has no instructions for AES: in the VM, one
  encryption and one decryption of 1 MiB take about 12 ms with
  ChaCha20-Poly1305, and 27 to 33 ms with AES-GCM. The TLS of an HTTPS
  request runs in the VM at the two ends.

- The WebAssembly runtime no longer stops sometimes with "Fatal error in
  ethr_mutex_unlock(): Operation not permitted" or "Executing aux work
  on a dirty scheduler". Under JSPI, `fsync()` and `select()` of the
  libc of Emscripten suspend the green thread. After the wait, the thread
  continued with the stack pointer and the identity of another thread.
  SQLite calls `fsync()` at each commit, so an app with SQLite stopped at
  its start in about 1 boot in 10. The runtime has its own `fsync()` and
  `select()` now, and its build stops at a new import that suspends. See
  EM6 in `docs/UPSTREAM.md`.
- The default `beam.com` has the OTP application `ssh`: a program can
  start an SSH daemon (`ssh:daemon/3`) or connect to one, with no custom
  build. A program has `ssh` only when it uses it, as with the other
  applications of the zip. A test of CI starts a daemon and connects to
  it on each system.
- A response of the app that ends before the end of its body is no
  longer a whole body for the client. When the app closes the connection,
  or ends its writes, before the last chunk or before the bytes of its
  `content-length`, the stream of the response fails. Bandit does this
  when a plug raises after `send_chunked/2`. In Workers, a response with a
  `content-length` keeps it (a `FixedLengthStream`): before, workerd sent
  it in chunks, and a short body ended normally. A client of Workers still
  cannot see a short body in chunks: see CF9 in `docs/UPSTREAM.md`.
- The fetch path keeps the `content-length` of a response when the body
  is not encoded, also for HEAD, and writes the body with no chunks.
  Before, each response came in chunks with no length, so a program
  could not know the size of a file that it streamed from a different
  site (for example a GET of a file of R2 with Req). A body that ends
  before its length closes the connection, and the bytes past the length
  do not go. An encoded body still comes decoded, in chunks, with no
  length.
- On x86_64, the VM no longer stops with SIGSEGV in `memchr()` when an
  empty binary ends exactly at the end of a mapping, for example in
  `erlang:decode_packet/3`. The `memchr()` of Cosmopolitan 4.0.2 read 16
  bytes also for a length of 0. See C33 in `docs/UPSTREAM.md`.
- `strncpy()` in the VM reads at most `n` bytes of its source. The
  `strncpy()` of Cosmopolitan read the source up to its NUL, so a source
  with no NUL at the end of a mapping made a fault. A test of CI calls 20
  functions of the libc at the edges of a mapping. See C34 in
  `docs/UPSTREAM.md`.
- The reader of the `metadata.config` of a Hex package refuses a float,
  such as `1.5`. Before, it read `1.5.` as the two terms `1` and `5`. A
  dot now ends a term only before white space, a comment or the end of
  the text, as in `erl_scan`.
- `gen_tcp` in the WebAssembly runtime (`wasm_tcp`) gives the results and
  the messages of `gen_tcp` of the BEAM (`inet_drv`). A new test does the
  same steps on a socket of `gen_tcp` on 127.0.0.1 and on a socket of
  `wasm_tcp`, and compares them. See "The sockets of the host and
  gen_tcp" in `docs/WORKERS.md` for the differences that stay.
- After the end of the peer of a passive socket, an active mode gives the
  rest of the data and then `{tcp_closed, S}`. Before, `{tcp_closed, S}`
  never came, and the process of the socket stayed.
- A listener that closes, or whose owner stops, closes the connections
  that no accept took, and each accept that waits gets `{error, closed}`.
  Before, these connections stayed open. An accept of a process that
  stopped no longer takes a connection.
- All the packet types of inet work: `http`, `http_bin`, `httph`,
  `httph_bin`, `asn1`, `cdr`, `sunrm`, `fcgi`, `tpkt`, `line` (with
  `line_delimiter`), with `packet_size` (`{error, emsgsize}`). Before, the
  socket kept them only for `getopts/2`, and a packet above `packet_size`
  made it ask the host for more bytes with no limit.
- `{active, N}` adds N to the counter, as in `gen_tcp` (the distribution
  over `wasm_tcp` expects it). Before, it replaced the counter.
- A second `recv` at the same time gets `{error, ealready}`. Before, it
  replaced the first one, which then got no answer.
- `controlling_process/2` gives the `tcp` and `tcp_closed` messages in the
  mailbox of the old owner to the new owner.
- `gen_tcp:shutdown(S, write)` ends only the data to the peer (the new
  message `tcp_shutdown` of the host), and the socket still reads.
  `read` and `read_write` work too. Before, a shutdown closed the socket.
- The bytes that `gen_tcp:unrecv/2` gives back no longer count two times
  in the flow control of the host (`tcp_read`).
- The options and the errors of `gen_tcp`: a wrong option gives `{error,
  einval}` (`connect/4` and `listen/2` exit with `badarg`), and
  `exit_on_close`, `show_econnreset`, `send_timeout`,
  `send_timeout_close`, `deliver`, `header` and `mode` work. The calls on
  a socket that closed give the errors of the BEAM, and `close/1` takes
  the `tcp_closed` of the socket from the mailbox.
- The fetch path: a header value or a path with bytes above 0x7F
  (obs-text) no longer stops the connection. The bytes go to `fetch()` as
  they are, and a path gets them as `%XX`. A connection that stops leaves
  no fetch behind in the host.
- The fetch path answers an HTTP/1.0 request with no chunked coding (RFC
  9112): the end of the connection ends the body. The answers of the
  server itself have a `content-length`.
- The fetch path answers 504 (Gateway Timeout) when the host gives no
  head of a response in 5 minutes. Before, it answered 502 "the host did
  not answer". The request may have run.
- `wasm:run/2` in the WebAssembly runtime leaves no process behind. Before,
  each call left two processes, until the end of the caller.
- The errors of the VM have the names of the BEAM. Before, 11 to 13
  POSIX errors, by host, had the name `errno_N`: for example, a loop of
  symbolic links gave `{error,errno_40}` in place of `{error,eloop}`,
  and `etimedout`, `ealready` and `enotempty` were also `errno_N`. The
  errors that only one host has, such as `eremoteio` on Linux and
  `eauth` on macOS and the BSDs, also have their names now. See C35 in
  `docs/UPSTREAM.md`.
- A response of the app before the end of a large request body goes at
  once again (a regression of 0.1.0-rc.5). Before, the response waited
  for the end of the upload, and the upload waited for the app. So an app
  that answered with 512 KB before it read a body of 2 MiB, or that
  streamed its response while it read the body, held its response for
  60 s. Now the end of the response waits for the end of the request
  body, so the next request on the connection still works.
- Security: a request body with more bytes than its `content-length`
  can no longer put a second request on the connection of the app.
  Before, the host gave the app the `content-length` and all the bytes
  of the body stream, for example of a `Request` of `boot()` in Node.js.
  Now the app gets at most that number of bytes. A body with more bytes
  or with fewer bytes gets 400, and the app gets the end of the
  connection.
- The 101 of a WebSocket has the headers of the 101 of the app, on
  Workers, Deno and in a web page: the subprotocol that the app chose
  and its cookies. Before, the host dropped them. So a browser that
  offered a subprotocol (`new WebSocket(url, ['graphql-transport-ws'])`,
  or a Phoenix 1.8 socket with `authToken`) failed the handshake, with
  "Sent non-empty 'Sec-WebSocket-Protocol' header but no response was
  received" in Chrome.
- The answers that the front Worker and the Durable Object make
  themselves (a 400 or a 404 of the routes of the tenants, a redirect,
  the 503 of an object that resets, the 410 of an instance that ended)
  read the rest of the request body first, as the answers of the VM do
  since 0.1.0-rc.5. Before, in `wrangler dev`, the next request on that
  connection got 500.
- Security: with `serve(app, { name })` and a function, the host removes
  the header `x-beam-tenant` of the client. Before, the app got the
  header of the client, which it trusts, and with `BEAM_TENANTS = "path"`
  the object also took `BEAM_TENANT` from it.
- A snapshot waits while an operation of WebAssembly of the application
  `wasm` runs in the host, and while the host keeps a module or an
  instance for the VM, as it waits for a socket. Before, a snapshot could
  copy a VM that waited for the reply of such an operation, and a VM that
  restored it waited forever, or used a handle that its host did not
  have.
- `BEAM_FETCH` keeps the rules of the fetch path. Port 443 goes through
  `fetch()` only with a trust store (`--cacerts`), also when a rule names
  it, and another port only when a rule names that port. Before, `*:443`
  with no `--cacerts` sent each HTTPS connection to a server whose CA the
  program did not trust, and `*` sent each connection, also of a
  database, to a server that speaks only HTTP. A rule with no port now
  gives ports 80 and 443. `specs/FetchPath.tla` models the rules.
- The file watcher (`inotifywait` on the BSDs, `mac_listener`) finds the
  entry of each file in an index of the paths. Before, a comparison of n
  files cost O(n²): with 20,000 files, the comparison every half second
  used half of one CPU or more, also when kqueue worked. Now it uses about
  10%.
- The file watcher (`inotifywait -r`, `mac_listener`) follows no symbolic
  link below a watched directory, as `inotifywait -r` of inotify-tools.
  Before, two links to a parent directory (`ln -s . a; ln -s . b`) made
  a walk that did not end, so no event came, and the link
  `_build/dev/lib/APP/priv` of Mix gave the changes of `priv/` under
  `_build/`. The watcher also goes into each directory one time, also
  through a bind mount. A link is an entry of its own: `mac_listener`
  gives it `issymlink`.
- The file watcher (`inotifywait` on the BSDs, `mac_listener`) gives
  only "removed" for a file that a process removes during a comparison.
  Before, a stat during the removal could see the link count 0 and a new
  ctime, and the watcher also gave `inodemetamod` (`ATTRIB`).
- A NIF library in WebAssembly can no longer give Erlang memory of the
  VM, or stop the VM, with a bad call that ERTS checks only in a debug
  build. Such a call now raises `error:{wasm_trap, Message}`: for
  example `enif_make_sub_binary` out of its binary (before, 1 MiB of
  memory of the VM for a 10-byte binary), a term of an other environment
  in a new term or in a result, the result of `enif_make_badarg` in
  `enif_term_type`, a second `enif_release_resource`, a map iterator of
  an earlier call, `enif_consume_timeslice` with no process, and a NIF
  or a callback of an other function type (before, a function with four
  results wrote past the arguments of the call). `enif_port_command` of
  a dirty NIF to a closed port gives 0 (ERTS 29.1.1 stops there). See
  "Checks" in `docs/NIFS.md`.
- A `load_nif/2` of a NIF library in WebAssembly that ERTS refuses (an
  upgrade, or a bad library) no longer keeps the module and its linear
  memory: before, each such call kept up to 4 GiB of address space.
- A build with Hex packages checks each tarball with a checksum of the
  lock or of the Hex API, also when the lock has no checksum for the
  package: `rebar.lock` of the formats 1.0.0 and 1.1.0, or a `mix.lock`
  entry of an older Hex. Before, such a lock took the tarball of the
  cache or of `HEX_MIRROR` with no check against a trusted checksum.
  The build then writes the lock again with the checksums, so the next
  build needs no request. The older `mix.lock` entries are no longer
  refused as "not a Hex package".
- A Hex tarball has at most 32 MiB, and its `contents.tar.gz` at most
  256 MiB without compression: two times the limits of hex.pm. A
  download stops after its limit, and the build refuses larger contents
  before it writes a file. Before, a download and an unpack had no
  limit. An error response with no length stops only at the timeout of
  60 s: see O25 in `docs/UPSTREAM.md`.
- `beam.com app.erl` builds the program again when the data of an input
  changes, also in the same second as the last run, or in the hour that
  the end of daylight saving time repeats. Before, the run compared the
  local times of change, with a resolution of 1 s, and could run the old
  program. A file next to the program in the cache keeps the SHA-256 of
  each input. A run with no change reads the data of no input.
- `pages-app.yml` checks the provenance of `beam.com` against the commit
  of the release tag, not the ref of the tag. A release from a run by
  hand reuses the tested build of `main`, and its attestation names
  `main`. So `pages-app.yml@v0.1.0-rc.4` and `@v0.1.0-rc.5` stop at
  "Check the provenance of beam.com": use `@v0.1.0-rc.6` or later. CI
  now runs this check on the newest release, and the release job runs it
  before it publishes.
- The release job waits for each test job of its run, also the tests of
  the npm package and of the web page. It stops when the commit of the
  tag is not on `main`, when a file has another version
  (`scripts/version.sh`), or when `CHANGELOG.md` has no section of the
  version. Each commit of `main` has its own CI group, so a merge does
  not stop the waiting run of the merge before it.
- On macOS arm64, the start of a port program no longer hangs. In CI, a
  child of `erl_child_setup` once faulted in the `fork()` of
  Cosmopolitan, before its `execve()`. The signals were blocked, so the
  child did not stop, and the emulator waited for it. `erl_child_setup`
  now uses the `fork()` of libSystem there. See C36 in
  `docs/UPSTREAM.md`.
- On macOS, a port program gets only the descriptors 0, 1 and 2. Before,
  it got each descriptor of the emulator that had no `FD_CLOEXEC`,
  because `closefrom()` did nothing. See C37 in `docs/UPSTREAM.md`.
- When a program of `tests/run.sh` hangs on macOS, the stacks in the log
  have the names of the functions (`tests/symtab.py`).

## 0.1.0-rc.5

The fifth release candidate of 0.1.0. As 0.1.0-rc.4, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
fixes from the check of 0.1.0-rc.4:

- An app that answers before it reads the whole request body (a 413 of
  its own, for example) no longer breaks the next request. Before, in
  `wrangler dev`, the next POST of any client got 500, and workerd logged
  "Uncaught TypeError: Can't read from request stream after response has
  been sent" for a Durable Object. Now the host reads the rest of the
  body and drops it before the response goes (64 MiB at most, and a stop
  after 5 s with no bytes), in a plain Worker, a Durable Object and Deno.
  The front Worker of a Durable Object pipes the body to the object
  itself, with a handler for a read that fails.
- A large request body that the app reads with a `recv` of a length (as
  Bandit reads a body) goes in parts of up to 1 MiB in place of 32 KB:
  each `tcp_read` of `wasm_tcp` tells the host how many bytes the `recv`
  still waits for. A body that the app reads in small parts still goes in
  parts of 32 KB, so the memory of the VM stays low. In `wrangler dev`,
  bodies of 2.7 MiB that the app reads with one `recv` each: 32.6
  requests each second for one client (0.1.0-rc.4: 19.0, 0.1.0-rc.2:
  28.2), and 60.2 for 16 clients (0.1.0-rc.4: 24.5, 0.1.0-rc.2: 17.7). With
  a Durable Object: 25.9 and 45.0 (0.1.0-rc.4: 15.0 and 17.4).
- The memory of the VM with large bodies at one time. In WebAssembly, a
  binary or a process heap of 512 KB or more got a carrier of its own,
  and the memory of the VM grew far above the memory that Erlang used
  (`erlang:memory/0` gave 14 MB in all). 16 clients that sent bodies of 2.7 MiB grew the memory of the VM to 345 MB
  with 0.1.0-rc.4 in workerd, and to more than 1 GB with the larger parts
  above. Now the peak is 202 MB. The host starts the VM with
  `-MBsbct 8192 -MHsbct 8192` (`BEAM_ERL_FLAGS` comes after them, and
  `-Mea min` turns them off). Also, data to an empty buffer of a socket
  is that buffer with no copy, and the data that completes a waiting
  `recv` makes one binary of its length, not of twice its length.

## 0.1.0-rc.4

The fourth release candidate of 0.1.0. As 0.1.0-rc.3, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
fixes from the check of 0.1.0-rc.3:

- Security: the events of a new connection keep their order. Before, a
  part of a request body could reach the app before the head of the
  request, when the VM was busy. A client could then make its body a
  request of its own, with header fields that only the Worker may set.
  Now the pump holds the events of a connection until the process of the
  connection claims it, and gives them to it first, in order.
- A `recv` of more than 256 KB gets its bytes. Before, a body above
  256 KB that the app read with one `recv` of its length (as Bandit reads
  a body) got no more bytes, and the request got 408 or no answer. Now
  the bytes count as read while the app waits for them.
- A request body goes in parts of 32 KB in place of 16 KB, and the head
  goes with the first bytes of the body (or alone, when they do not come
  in 20 ms). A small request is one event again, as in rc.2. In Node.js,
  20 bodies of 2.5 MB that the app reads with one `recv` each take 0.3 to
  0.6 s (rc.2: 1.6 s). Parts of 64 KB made the memory of the VM in Deno
  grow to 110 MB with the uploads of 32 MB, so the parts stay at 32 KB.

## 0.1.0-rc.3

The third release candidate of 0.1.0. As 0.1.0-rc.2, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
fixes from the feedback on 0.1.0-rc.2, and these changes:

- A VM that stops (`erlang:halt/1`, or a trap such as an allocation that
  failed) no longer holds its requests. Each open request gets 503 with
  `retry-after: 1`, each WebSocket closes with the code 1011, and the next
  request gets a new VM: a stateless Worker or Deno starts one, and a
  Durable Object resets. Before, the open requests and all later requests
  of that VM waited with no answer. In a plain Worker, the stop now runs
  in an open request, because the thread that stopped can run in the
  context of a request that ended.
- `BEAM_REQUEST_TIMEOUT` (60 s by default, `"0"` turns it off): a request
  gets 504 when the app does not listen, or does not send the head of its
  response, in this time.
- `BEAM_MAX_REQUESTS` and `BEAM_MAX_WEBSOCKETS`: above these counts, a new
  request or WebSocket gets 503 with `retry-after: 1` before the app reads
  its body. There is no limit by default.
- The host writes `beam: memory N MB (a new peak of this VM)` when the
  memory of the VM grew by 8 MB or more, and the memory of the VM when it
  stops.
- A process that computes no longer holds a Durable Object or Deno. The
  scheduler gives the host a turn after each 20000 reductions, so that
  new requests, timers and sockets run. In a Durable Object, one turn for
  each `BEAM_YIELD_REDS` reductions (1000000 by default) waits for a
  timer, and a request then waits about 150 ms in place of the whole
  work. Long work is about 6% slower. A stateless Worker has no such
  turns yet.
- A request body goes to the app in parts, as the client sends it, with
  flow control: the host sends a part only while less than 256 KB is
  unread in the VM (the new event `tcp_read` of `wasm_tcp`). Before, the
  host read the whole body first, and the VM held several copies of it:
  an upload of 32 MB made the memory of the VM grow to 208 MB (a Worker
  has 128 MB). Now it stays at about 40 MB. A body with no
  `content-length` goes as `transfer-encoding: chunked`.
- `BEAM_MAX_BODY`: a request body above this count of bytes gets 413. For
  a request with a body, `BEAM_REQUEST_TIMEOUT` starts at the end of the
  body.
- In a plain Worker, a line of the VM (stdout and stderr) that the host
  cannot write in the context of its thread goes to an open request.
  Before, `console.log` could throw there, and stop the thread of the VM.
- `beam.com INPUT -o edge.com --target wasm32` (an output that ends with
  `.com`) writes only the part that the WebAssembly runtime reads: a zip
  with the release and the edge part, with no native program. Another
  output of `--target wasm32` is still the runtime directory. It is about 25 MB smaller, so a Worker with a
  snapshot of the build stays below the 64 MiB of a Worker, and the VM
  gets about 25 MB more of the memory of the isolate.
- `npx beam.com --snapshot` writes the pages of the snapshot in gzip (about
  a quarter of the size; `--no-compress` writes them as they are). The
  host inflates them before the restore, in about 150 ms. A full snapshot
  (`--full`) has no gzip: a stateless Worker restores it in the global
  scope, which cannot inflate. A full snapshot in gzip restores in the
  first request.
- A response of the app goes to the client as the pieces come, with no
  new copy of the whole buffer for each piece. Before, the host joined
  each piece to the buffer, and copied an incomplete chunk again with
  each piece of it. The data of a large chunk now goes to the client
  before the end of the chunk. A bad chunked body stops the response.
- `npx beam.com --snapshot` reads `BEAM_ERL_FLAGS` from the `vars` of
  `wrangler.jsonc` when `--env` does not give it, and warns when the app
  file and the snapshot are near the 64 MiB of a Worker.
- `docs/WORKERS.md` has "Memory and capacity": the costs of an isolate,
  the limit that `wrangler dev` does not apply, one acceptor for Bandit,
  and the capacity of one Durable Object.
- The header of a snapshot keeps `BEAM_ERL_FLAGS`, and a Worker with other
  flags boots in place of the snapshot of the build. Give the flags of the
  Worker to `npx beam.com --snapshot --env BEAM_ERL_FLAGS=...`. Before, a
  snapshot made with no flags gave a Worker with `-Mea min` the
  allocators of ERTS, and 30 MB more memory.
- The bridge of the host is more robust:
  - A response of the app with a bad head (a status outside 100 to 599,
    a head above 1 MiB) gets 502, and the VM goes on. Before, an
    exception there stopped the thread of the VM.
  - The host skips a `1xx` head of the app (`100 Continue`, `103 Early
    Hints`) and waits for the final head. It removes `expect` from the
    request, because the host already has the body.
  - The head of a request and of a response is Latin-1, as in HTTP/1.1.
    Before, a header with bytes above 127 changed.
  - A client that cancels its request closes the connection of the app.
  - A request that waits for the listener of the app, or for a snapshot,
    stops when the VM stops, and leaves no wait behind.
  - An exception of the host on a message of the VM goes to the log, and
    does not stop the VM.
- `wasm_tcp` forgets each connection of a listener when its process
  stops. Before, the map of the listener grew with each connection.
- `BEAM_PERSIST`: a VM that stops saves the files that it wrote after the
  last save. Before, a stop lost up to 1 s of writes.
- The fetch path stops the `fetch()` of a request when the app closes its
  connection, and the cache of names holds at most 1024 names.
- A Durable Object that the host cannot reset (`ctx.abort` throws) starts
  a new VM at the next request. Before, it gave 503 to each request.
- A Worker whose snapshot does not restore in the global scope boots a VM
  in each request, and writes the cause to the log.
- `npx beam.com` stops the download of `beam.com` when no bytes come in
  60 s, and gives an error when the file cannot be written.
- A re-run of the release job after npm has the version keeps the
  `beam.com` that the npm package names (its SHA-256), and puts the
  tarball of npm on the release. A re-run with another `beam.com` stops
  with an error. Before, a re-run could replace the file of the release,
  and `npx beam.com` then refused the download.
- Flow control in the two directions. A send of the app waits while
  256 KB or more of its socket waits for the peer (the new event
  `tcp_sent` of `wasm_tcp`), so a client that reads slowly slows the app.
  In Node.js, a download of 64 MiB to a slow client held 64 MB in the
  host, and now 3 MB. The messages of a WebSocket client, a `connect()`
  socket, and the body of a `fetch()` of the fetch path go to the VM
  while less than 256 KB is unread there. A WebSocket whose app reads
  too slowly closes with the code 1008 above 16 MiB that wait.
- `gen_tcp:send/2` on a socket that the peer closed gives
  `{error, closed}`. Before, it gave `ok`.

## 0.1.0-rc.2

The second release candidate of 0.1.0. As 0.1.0-rc.1, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
fixes from the check of the examples with 0.1.0-rc.1, and these changes:

- The tools of Elixir (`mix`, `iex`, `elixir`, `elixirc`) put an
  `escript` in `PATH` when it has none, so Mix can run rebar3 for a
  dependency that is a rebar3 project. Before, the build of
  `examples/phoenix_demo` with `npx beam.com` (the Deploy buttons, Workers
  Builds and Deno Deploy) stopped at `idna`.
- `beam.com DIR` reads a `mix.lock` that Mix wrote (`"name": {...}`), with
  no warnings. Before, it stopped with `badarg`.
- `beam.com DIR` writes `mix.lock` for a package that rebar3 builds.
  Before, it stopped with `badarg` (`examples/notes` with no `mix.lock`).
- The Cloudflare host gives the app `x-forwarded-proto`, as the Deno host
  and the web page do. Before, `force_ssl` of Phoenix redirected each
  request.
- The help of `--cacerts` and `docs/WORKERS.md` say that `--cacerts` also
  works with `-o app.com` (the edge part of the file).
- Outgoing HTTP (port 80) and HTTPS (port 443, with `--cacerts`) go
  through `fetch()` of the host, and `connect()` is only for other
  protocols. So the VM also reaches a host behind Cloudflare
  (api.cloudflare.com, many webhooks), which `connect()` of Cloudflare
  cannot reach. The program and its configuration do not change. A
  WebSocket goes through a tunnel of `connect()`. `BEAM_FETCH` gives
  other hosts and ports. See "HTTP through fetch()" in `docs/WORKERS.md`,
  and `specs/FetchPath.tla`.
- `worker.capnp` gives workerd TLS for `fetch()` to `https://` URLs.
- `beam.com INPUT -o DIR --page` writes a static site that runs the app
  in the browser: `DIR/app.com`, the page and its runtime, with no CDN.
  The build does not run the release, so it needs no database and no
  secret. `pages-app.yml`, the Livebook page, the shell at `repl/` and
  the studio at `phx/` of the site of BEAM.com use it. Before, they used
  the full directory of `--target wasm32`. `start()` of the page takes
  `statics: false` for an app that serves `priv/static` at a path other
  than `/` (the studio). `BEAM_COM_BASE` names the APE file that a native
  (assimilated) `beam.com` copies for a build, so that it still makes APE
  files.
- `npx beam.com --snapshot app.com` writes the snapshot of the build of
  `app.com`, and `serve(app, { snapshot })` gives it to the VMs. A full
  snapshot (`--full`) replaces the boot: a stateless Worker restores its
  VM in the global scope, and the first request of a new isolate took 82
  to 107 ms of CPU on Cloudflare (213 to 483 ms with the snapshot of the
  store). A snapshot at the boot point (the default) holds no variable of
  the app: a VM restores it only when the store has no snapshot yet, so
  the first isolate of a deploy took 844 ms (1,695 ms with a boot). See
  "The snapshot of the build" in `docs/WORKERS.md`.
- `--target wasm32` is internal. The help, `README.md` and
  `docs/WORKERS.md` no longer show it: `app.com` with the npm package
  (`serve(app)`, `--snapshot`, `--nif-modules`) and `--page` do what it
  did. The option stays for the build of the npm package and for the
  scripts of the examples. "The runtime directory (internal)" in
  `docs/BUILDING.md` gives its files. This change removes
  `examples/phoenix_demo/scripts/wasm.sh`.
- `serve(app, { statics: false })` keeps the static files of a Phoenix
  app in the VM, for an app that serves them at another path
  (`Plug.Static` with `at:`). By default, the host serves them at the
  root of the site, before the VM. `boot()` of Node.js takes the same
  option. `examples/studio` is now a project of `app.com` with the npm
  package, with `worker.js` and `wrangler.jsonc`, in place of
  `scripts/wasm.sh` and `--target wasm32`.
- The GitHub release holds the tarball of the npm package
  (`beam.com-VERSION.tgz`), with its attestation and its line in
  `SHA256SUMS`. It is the file that the release job publishes on npm, so
  `npm install URL` of the release installs the package with no
  registry.
- On macOS arm64, the VM starts `erl_child_setup` with `posix_spawn()`
  of libSystem, through the APE loader. Before, it used `fork()`, and the
  child could hang in `_objc_atfork_child`: a process stayed after the VM
  stopped. See C32 in `docs/UPSTREAM.md`.

## 0.1.0-rc.1

The first release candidate of 0.1.0. It is a pre-release on GitHub, and
on npm it has the dist-tag `next` (`npm install beam.com@next`).

- Erlang/OTP 29.1.1 and Elixir 1.20.4 in one executable file for Linux,
  macOS, Windows, FreeBSD, NetBSD and OpenBSD, on x86_64 and aarch64,
  with the JIT (BeamAsm) for both CPUs. `beam-emu.com` has the
  interpreter.
- `beam.com INPUT` runs and `beam.com INPUT -o OUTPUT` builds `.erl` and
  `.ex` files, applications, and rebar3 and Mix projects, with Hex
  packages, and with no Erlang installation. `mix`, `iex`, `elixir`,
  `elixirc` and `escript` are in the file.
- Static nifs: `crypto` (OpenSSL 4.0.2), SQLite 3.53.4 (esqlite and
  exqlite), WebAssembly and WASI (WAMR 2.4.5), bcrypt_elixir and
  argon2_elixir.
- NIF libraries in WebAssembly: when a NIF has no native library,
  `load_nif/2` loads `PATH.wasm`, or its AOT file `PATH.x86_64.aot` or
  `PATH.aarch64.aot`, through WAMR, also from the zip of a program. One
  `.wasm` file works on all the systems, and in the WebAssembly runtime
  of `--target wasm32`, where the engine of the host runs it. `beam.com
  --nif-include` gives the headers. A snapshot of the edge holds these
  libraries too, and `beam.com --nif-modules` gives them to a Worker
  that runs an `app.com` (`serve(app, { nifs })`). lazy_html (the HTML
  parser of Phoenix.LiveViewTest) passes its tests so. See
  `docs/NIFS.md`. `beam.com` has lazy_html 0.1.13 in WebAssembly: a Mix
  project with it needs no C++ compiler.
- The OTP application `tools`, for `mix test --cover`.
- A sandbox with the permission flags of Deno (`--allow-read`,
  `--allow-write`, `--allow-net`, `--allow-run`), on Linux and OpenBSD.
- `--target wasm32`: a second runtime, ERTS on WebAssembly with green
  threads on JSPI. One output runs on Cloudflare Workers (Durable
  Objects, D1, snapshots, tenants), on Deno Deploy (SQLite with its
  pages in Deno KV), and in a web page. Phoenix LiveView and Livebook
  run on it.
- Each native `app.com` holds an edge part: the same app runs on
  Cloudflare Workers, on Deno Deploy, and in a web page, with no second
  build.
- The npm package `beam.com`: `npx beam.com` downloads the `beam.com` of
  the release and checks its SHA-256. `import { serve } from 'beam.com'`
  gives a `fetch` handler for an `app.com`, on Cloudflare Workers and on
  Deno. The `exports` map of the package selects the file for each
  runtime.
- `serve(app)` is stateless by default: one VM for each isolate. With
  the binding `BEAM` and `export { Beam } from 'beam.com'`, it is
  stateful: one Durable Object holds the VM and its SQLite storage.
- A Phoenix app gets `SECRET_KEY_BASE` and `PHX_HOST` automatically. The
  key stays in the storage of the Durable Object or in Deno KV.
- A static site for a native `app.com`: the page comes from a CDN (for
  example jsDelivr), and it reads `app.com` with range requests.
- Two templates with Deploy buttons for Cloudflare and Deno Deploy:
  `examples/phoenix_demo` (stateful) and `examples/worker` (stateless).
  Each host builds the app at each git push.
- The documentation is a set of Livebook notebooks that run in the
  browser: <https://sntran.github.io/BEAM.com/>.

See [`docs/PLATFORMS.md`](docs/PLATFORMS.md) for the known limits.
