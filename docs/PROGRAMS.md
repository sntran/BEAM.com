# Run and build programs

This file is the manual of `beam.com INPUT` (run a program) and
`beam.com INPUT -o OUTPUT` (make an executable of it). For Elixir and
Phoenix, see [`ELIXIR.md`](ELIXIR.md). For Cloudflare Workers, see
[`WORKERS.md`](WORKERS.md).

## The command line

```sh
beam.com [FLAGS] [INPUT] [-- ARGUMENTS]    # run INPUT (default: the project here)
beam.com [FLAGS] INPUT -o OUTPUT           # make the executable OUTPUT

FLAGS: [-a APP]... [--allow-read[=PATH,...]] [--allow-write[=PATH,...]]
       [--allow-net[=HOST,...]] [--allow-run[=PROGRAM,...]] [--allow-all]
       [--target TARGET] [--main MODULE] [--tool rebar|mix|mix-release]
       [--extract-priv APP]... [--cacerts FILE]
```

There is one command line, as for `npm run`: the flags can come before
or after `INPUT`, and the arguments of the program come after `--`.
`beam.com app.erl -- one two` runs `app.erl` with the arguments `one`
and `two`; `beam.com app.erl -o app.com` makes `app.com`. A run makes
the same executable in the cache of BEAM.com (`BEAM_COM_CACHE`, else
`~/.cache/beam.com/run`), again only when the data of a file of `INPUT`
or of `beam.com` changes, and runs it: the program gets the terminal,
and its exit status is the exit status of `beam.com`. In a directory
with `mix.exs`, `rebar.config` or `src/`, `beam.com` alone runs that
project.

The SHA-256 of each file decides, not its time of change: a change in
the same second as the last run, or in the hour that the end of daylight
saving time repeats, makes a new build. A file next to the executable
in the cache (its name and `.inputs`) keeps the SHA-256, the size and
the time of each file. A run reads a file again only when its size or
its time changed, or when its time is less than 2 s before the time of
its last hash. So a run with no change reads the data of no input, as
before. The directories `_build`, `deps`, `.git` and `.elixir_ls` are
not inputs. The build itself writes `rebar.lock` and `mix.lock`, and the
Mix steps write files in `priv/` (for example the assets and
`cache_manifest.json` of a Phoenix app). A run keeps the data of these
files from after the build, so the next run does not build again. A
change of a file of `priv/` during the build thus does not start a new
build.

`INPUT` is one of these:

- **One `.erl` file** that exports `main/1`, as for `escript`. The
  program gets the command line arguments, and halts with status 0 when
  `main/1` returns (127 on an exception).
- **An application directory**: `src/*.erl` (subdirectories too),
  `src/NAME.app.src` or `ebin/NAME.app`, and optionally `include/`,
  `priv/`, `config/sys.config`, `config/vm.args` (the rebar3 layout) and
  the `erl_opts` of `rebar.config`. Parsers (`src/*.yrl`, yecc),
  scanners (`src/*.xrl`, leex) and ASN.1 modules (`asn1/*.asn1` or
  `src/*.asn1`, `.asn` too; BER) are made into Erlang code first. The
  modules that other files name in `-behaviour` or as a
  `parse_transform` are compiled first, as rebar3 does. The `deps` of
  `rebar.config` are Hex packages and git deps (see below). An application can also
  have an entry, as an escript: see "Command line programs" below.
- **One Elixir file** (`.ex` or `.exs`) in which one module exports
  `main/1`, or **a Mix project** (`mix.exs`): see
  [`ELIXIR.md`](ELIXIR.md).
- **A release directory** without ERTS (from `mix release` or rebar3):
  see "One file, natively and at the edge" in [`WORKERS.md`](WORKERS.md).

The builder compiles the code, selects the OTP applications that the
program needs, makes an OTP release with `systools`, and writes a copy of
`beam.com` with the release in its zip (`OUTPUT`). The new file does
not have the compiler, only what the program needs.

The applications are the ones that the `.app` file names, the ones of
the modules that the code calls (from the imports of the compiled code),
and all the applications that these need. Use `-a APP` for an
application that the code only calls with `apply/3` or similar.

The zip of `beam.com` has these applications:

- OTP: `kernel`, `stdlib`, `sasl`, `compiler`, `parsetools`, `crypto`,
  `asn1`, `public_key`, `ssl`, `inets`, `ssh`, `xmerl` and
  `runtime_tools`.
- Elixir: `elixir`, `eex`, `ex_unit`, `iex`, `logger` and `mix`.
- BEAM.com: `wasm` (WebAssembly), `esqlite` (SQLite), `wasm_host` (for
  the WebAssembly runtime) and `beam_com_script` (for one-file programs).

A custom build can add more OTP applications: open an issue with the form
[A custom build of beam.com](https://github.com/sntran/BEAM.com/issues/new?template=custom_build.yml),
and CI builds the file for you (see "A custom build" in
[`BUILDING.md`](BUILDING.md)).

## Hex packages

The `deps` of `rebar.config` are fetched from [hex.pm](https://hex.pm)
and compiled into the program, as rebar3 does, without rebar3:

```erlang
{deps, [{cowboy, "~> 2.13"},       % a Hex requirement
        {jsx, "3.1.0"},            % this version only
        recon,                     % the highest version
        {mylib, "~> 1.0", {pkg, my_lib}}]}.  % another package name
```

- **Versions.** When `rebar.lock` has all the deps, its versions are
  used, and nothing is resolved. Otherwise the builder takes the
  highest version of each package that matches all the requirements (of
  `rebar.config` and of the packages), the locked version first when it
  matches, and writes `rebar.lock` (the format of rebar3). A conflict
  is an error that names both requirements; a version in `rebar.config`
  solves it. Pre-releases are used only when a requirement names one.
- **Checks.** Each tarball is checked with the outer checksum (SHA-256
  of the file: `pkg_hash_ext` of `rebar.lock`, else the checksum of the
  Hex API) and the inner checksum (`pkg_hash`, and the `CHECKSUM` file).
  The check also applies to a tarball of the cache and of `HEX_MIRROR`.
  When `rebar.lock` has no `pkg_hash_ext` for a package (the formats
  1.0.0 and 1.1.0 of rebar3), the builder gets the checksum from the Hex
  API, as rebar3 checks such a lock with the registry. Then it writes
  `rebar.lock` again, with both checksums and the same versions and
  levels, so the next build needs no request. The same rules apply to
  `mix.lock`, also to an entry that an older version of Hex wrote (with
  no outer checksum, or with no checksum). When the builder writes
  `mix.lock` again, the entries of the deps that the build does not use
  (for example the deps only for `:dev`, also git deps) stay as they
  are. Only an entry that the build uses must be a Hex package of
  hex.pm. A git entry of `rebar.lock` with no git dep in `rebar.config`
  gives one line, and the builder leaves it out, as rebar3 does.
- **Limits.** A tarball has at most 32 MiB, and its `contents.tar.gz` at
  most 256 MiB without compression: two times the limits of hex.pm (16
  MiB and 128 MiB). A download stops when it gets more than the limit,
  and the builder writes no file of a package whose contents are larger.
  The builder does not read a tarball of the cache that is larger: it
  downloads the tarball again.
- **Cache.** The tarballs are kept in the cache of the user
  (`~/.cache/beam.com` on Linux; `BEAM_COM_CACHE` changes it). With
  `rebar.lock` (with its checksums) and a full cache, a build does not
  use the network.
- **Network.** HTTPS with `httpc`, verified with the certificates of
  the OS, or of the file of `SSL_CERT_FILE` when it is set (see "Crypto
  and TLS" in [`INTERNALS.md`](INTERNALS.md)). `HTTPS_PROXY` and
  `NO_PROXY` are used. A proxy with no port uses the port of curl: 443
  for `https://`, else 1080. `HEX_API_URL` (default
  `https://hex.pm/api`) and `HEX_MIRROR` (default `https://repo.hex.pm`)
  select other servers.
- **Build.** The packages are compiled in order (a package after the
  packages that it needs), with their `erl_opts` (without
  `warnings_as_errors`), and their warnings are not shown. A package
  can use the parse transforms and the headers (`include_lib`) of the
  packages that it needs.
- **Not supported:** other sources (for example `hg`), NIFs (C code)
  and rebar3 plugins or hooks. Elixir packages (Mix) are supported: see
  [`ELIXIR.md`](ELIXIR.md).

### Git deps

A dep of `rebar.config` can also come from a git repository of an
`https` or SSH URL, in the forms of rebar3:

```erlang
{deps, [{jsx, {git, "https://github.com/talentdeficit/jsx.git", {tag, "v3.1.0"}}},
        {mylib, {git, "git@github.com:org/mylib.git", {branch, "main"}}},
        {other, {git_subdir, "https://example.com/mono.git",
                 {ref, "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"}, "apps/other"}}]}.
```

- The git client of `beam.com` (`beam_com_git`) gets the commit, with
  no `git` program: version 2 of the git protocol over HTTPS or SSH,
  with depth 1. It computes the name of each object from its data. See
  "Git over SSH" below.
- `{ref, R}` is a commit with all its 40 hex digits, or the name of a
  ref. A shorter commit (`1a2b3c4`) does not work: the git protocol
  fetches only a complete name. As with `git`, a tag comes before a
  branch of the same name.
- `rebar.lock` keeps the commit of each git dep, as rebar3 does:
  `{git, URL, {ref, SHA}}`. A build with the lock gets this commit, and
  does not ask the server for the branch or the tag.
- The builder also gets the deps of a git dep (its `rebar.config`): Hex
  packages and git deps. The name of a git dep must be the name of an
  application (letters, digits and `_`), and the directory of
  `git_subdir` a relative path in the checkout with no `..`.
- The version of a git dep is the `vsn` of its `.app.src`. For the
  `vsn` `git`, it is the tag without `v`, else `0.0.0+git.` and the
  first 7 characters of the commit.
- **HTTPS.** A request can take one hour, and it stops after 120 s with
  no data. The client follows at most 5 redirects of `info/refs`, only
  to an `https` URL, and it sends the next requests to the new URL, as
  `git` does. The user and the password of the URL go only to its host.
- **The checkout.** A tree with two entries of the same name stops the
  build, also when the names differ only in the letter case (as for a
  file system that ignores it). Each file, directory and link of the
  checkout is new, so a write follows no link. A link must stay in the
  checkout: a relative target with no `..`, no `\`, no `:` and no part
  `.git`.
- **The names `.git`.** An entry or a part of a link that Windows or
  macOS reads as `.git` is an error, on each system, as with
  `core.protectNTFS` and `core.protectHFS` of git: for example `.git.`,
  `.git `, `GIT~1`, `.git::$INDEX_ALLOCATION`, or `.git` with a code
  point that HFS+ ignores (U+200C).
- **SHA-1 collisions.** The name of a git object is a SHA-1, and with a
  SHA-1 collision two different objects can have one name. So the client
  checks each object of a pack with the collision detection of git
  (sha1dc, the library sha1collisiondetection). The helper program
  `git_sha1dc` of `beam.com` does the check in a process of its own,
  while the client resolves the deltas. An object with the mark of a
  collision attack stops the build before the checkout writes a file:
  `git: the object NAME has the mark of a SHA-1 collision attack`.
- **When the check runs.** Each `beam.com` after 0.1.0-rc.6 has the
  helper, and its git client always checks the objects. No setting and
  no environment variable stops the check. A helper that does not start,
  that stops, that gives a wrong digest, or that gives no answer in
  120 s also stops the build. The checksum at the end of the pack stays
  plain SHA-1: it finds damaged bytes of the transfer, not an attack.
- **Limits.** The list of refs has at most 16 MiB, and the pack at most
  512 MiB. One object of the pack (also a delta and its result) has at
  most 256 MiB, and all the objects, with the results of the deltas, at
  most 1 GiB. The client stops the inflate of an object at the size in
  its header. A server that sends more stops the build.

### Git over SSH

The git client speaks SSH with the `ssh` application of OTP, with no
`ssh` program. It accepts `ssh://[user@]host[:port]/path` and the form
of scp, `[user@]host:path` (for example `git@github.com:org/repo.git`).
On Windows, a host of one letter is a drive, as for `git`: `C:/repos/dep`
is a path, not an SSH URL.
The same client gets the git deps of Mix with no `git` program (see
"Phoenix in one file" in [`ELIXIR.md`](ELIXIR.md)).

- **Settings.** It reads `~/.ssh/config` as `ssh` does, the first value
  of each keyword: `Host`, `Match all`, `Include`, `HostName`, `User`,
  `Port`, `IdentityFile`, `IdentitiesOnly`, `IdentityAgent`,
  `UserKnownHostsFile` and `HostKeyAlias`. It does not read
  `/etc/ssh/ssh_config`.
- **Keys.** The SSH agent of `SSH_AUTH_SOCK` (a key that only the agent
  has, for example of a password manager), and the key files:
  `IdentityFile`, else `~/.ssh/id_ed25519`, `id_ecdsa` and `id_rsa`.
  The client tries at most 4 keys of each type: one connection for each
  round of keys. It starts the next round only when the server refused
  each key of a round.
- **The agent on Windows.** With no `SSH_AUTH_SOCK`, the client uses the
  agent of Windows OpenSSH, the named pipe `\\.\pipe\openssh-ssh-agent`.
  Start the service and add your key once:

  ```powershell
  Set-Service ssh-agent -StartupType Automatic   # as an administrator
  Start-Service ssh-agent
  ssh-add $HOME\.ssh\id_ed25519
  ```

  `IdentityAgent` or `SSH_AUTH_SOCK` can name another pipe. Erlang
  cannot open a named pipe (C55 of [`UPSTREAM.md`](UPSTREAM.md)), so
  the helper program `ssh_agent_bridge` of `beam.com` connects to it.
- **A key with a passphrase.** The client asks no question. Add the key
  to the agent (`ssh-add`). The error names each key file with a
  passphrase.
- **The signature of the agent.** The client waits at most 60 s for a
  signature, so a person can confirm the key in the agent. When the
  agent does not sign, the client tries the next key. The error names
  the fingerprint of each key that the agent did not sign with.
- **Host keys.** The key of the host must be in `~/.ssh/known_hosts`
  (also a hashed name, and `[host]:port`), or in
  `/etc/ssh/ssh_known_hosts`. For an unknown host, the build stops with
  the fingerprint of its key. The client writes no file. A key with
  `@revoked` stops the build.
- **The protocol.** The client runs `git-upload-pack` on the server
  with `GIT_PROTOCOL=version=2`. A server that refuses the variable (the
  default of OpenSSH) speaks version 0, and the client uses it: the
  commit must then be a branch or a tag of the server, or the server
  must allow other commits (`uploadpack.allowReachableSHA1InWant`).
- **Not supported.** `ProxyJump` and `ProxyCommand`, `GIT_SSH_COMMAND`
  and `GIT_SSH` (they name a program), the keys of a FIDO token
  (`sk-*`, which the `ssh` application does not have). Use the `git`
  program for these.

[`examples/hexweb`](../examples/hexweb) uses cowboy (with cowlib and
ranch) and jsx: it starts a web server and gets JSON from it. CI builds
it on each platform, two times (with and without `rebar.lock`).

## Command line programs: `--main`, `priv` files and erl mode

An application directory can be a command line program, as an escript
made with `rebar3 escriptize` or `mix escript.build`. The builder takes
the module whose `main/1` runs:

- `--main MODULE`, or
- `rebar.config`: `-escript main MODULE` in `escript_emu_args`, else
  `escript_main_app` (the module with the name of the application), or
- `mix.exs`: `escript: [main_module: MODULE]`.

The release starts all the applications first; then `MODULE:main/1`
gets the command line arguments (as strings; as binaries for an Elixir
module), and the program halts with status 0 when `main/1` returns (127
on an exception), as for one `.erl` file. `vm.args` gets
`-s beam_com_script main MODULE`. A directory with both `rebar.config`
and `mix.exs` is built as a rebar3 project; `--tool mix` selects Mix.
A Mix project that needs Mix itself (for example a Phoenix app) gets a
release from Mix, and `--tool mix-release` asks for it (see "Phoenix in
one file" in [`ELIXIR.md`](ELIXIR.md)).

**`priv` files as real files.** Code reads `priv` from the zip
(`code:priv_dir/1` is in `/zip`), which works for `file:read_file/1`,
but other programs (`sh`, a tool that gets a path) cannot read `/zip`.
`CACHE` is `$BEAM_COM_CACHE`, else the user cache directory
(`filename:basedir(user_cache, "beam.com")`: `~/Library/Caches/beam.com`
on macOS, `$XDG_CACHE_HOME/beam.com` or `~/.cache/beam.com` on the other
systems, Windows too).

- **A program of the zip.** A file of the zip with an execute bit runs
  as a port program from its `/zip` path, for example
  `open_port({spawn_executable, filename:join(code:priv_dir(app),
  "bin/tailwind")}, ...)` or `System.cmd/3`. The builder keeps the
  execute bit of each file of `priv` in the zip, and the entry
  `.programs` of the zip has the SHA-256 and the size of each such file.
  `os:find_executable/1` and the check of `open_port/2` see the entry:
  it exists, and it has an execute bit. The arguments, `argv[0]`, the
  environment, the file descriptors and the directory of the program are
  the same as for a program on the disk. Only the paths `/zip/bin/NAME`
  of the helper programs (`erl_child_setup`, `inet_gethost`, `epmd`,
  `inotifywait`, `mac_listener`, `ssh_agent_bridge`, `git_sha1dc`,
  `make`, `erl` and the tools `mix`, `iex`, `elixir`, `elixirc`,
  `escript`, `rebar3`) start the file of the program again
  (`beam_com_zip_helper()` in `c_src/cosmo/beam_com_zipexec.c`).
- **Linux: a memfd.** The kernel cannot start a file of the zip, so
  beam.com copies the bytes of an ELF program to a new memfd
  (`memfd_create()` with `MFD_CLOEXEC`, and `MFD_EXEC` where the kernel
  has it), seals it (`F_SEAL_SHRINK`, `F_SEAL_GROW`, `F_SEAL_WRITE`,
  `F_SEAL_SEAL`), and starts it through `/proc/self/fd/N`. Nothing goes
  to the disk. `/proc/self/exe` of the program is the memfd, so a program
  that reads its own file works: the tailwind program of Tailwind CSS 4
  is one file of Bun, and `tests/run.sh` runs it from a memfd. The path
  of `/proc/self/exe` is `/memfd:NAME (deleted)`, so a program that
  needs that name (for example the multi-call tools of uutils, which
  compare it with the name of the tool) does not run: start it with
  `BEAM_COM_MEMFD=0` in the environment of the VM. When the
  kernel refuses (`vm.memfd_noexec=2`, an old kernel, no `/proc`), for
  a script or an APE file, in a sandbox, and with `BEAM_COM_MEMFD=0`,
  the program runs from its copy in the cache.
- **The other systems: a copy in the cache.** On macOS, Windows,
  FreeBSD, NetBSD and OpenBSD, the program runs from
  `CACHE/bin/SHA256/NAME`, where `SHA256` is the SHA-256 of its bytes
  (from `.programs`) and `NAME` is its name (with `.exe` on Windows when
  the name has no suffix). The first start writes the copy one time: a
  new file in that directory, with `O_EXCL` and the mode 0500, all the
  bytes, `fsync()`, then a link or `rename()` to its name. A program
  that starts at the same time sees no half file, and beam.com never
  changes a copy (macOS stops a signed program when its file changes).
  The next starts use the copy with no new write. beam.com makes the
  directories `CACHE/bin` and `CACHE/bin/SHA256` with the mode 0700.
- **The checks of the copy.** Before each start, `CACHE/bin` and
  `CACHE/bin/SHA256` must be real directories (no symbolic link) of the
  user, which other users cannot write, and the copy must be a regular
  file of the user with the size of the program, which other users
  cannot write. Else the start fails with an error on the standard error
  ("... another user can write it: beam.com runs no program from it"),
  and nothing runs. beam.com does not read the whole copy again at each
  start: only the user can change it, and a SHA-256 of 100 MB takes
  about 0.4 s. On Windows, the access lists of the profile of the user
  protect the cache: Cosmopolitan gives each file the user of the
  process and modes with no meaning there.
- **A shell cannot run a program of the zip.** `os:cmd/1`, `{spawn,
  Command}` and `sh -c` give the command to `sh`, and `sh` cannot read
  `/zip`. Use `spawn_executable` (or `System.cmd/3`) with the path of
  the program.
- **A directory of real files.** A program that needs the files next to
  it, or a tool that reads a data file of `priv`, needs the whole
  directory. The builder of a project (not a release) copies the `priv`
  directory of each application whose `priv` has an executable file, or
  that `--extract-priv APP` names. For a Mix or rebar3 release
  (`beam.com DIR -o FILE` with a release), only `--extract-priv APP`
  does it: a program of the zip runs as it is, and a copy of a large
  `priv` (the static files of Phoenix) costs time and disk at the first
  start. The program copies that `priv` directory at its first start to
  `CACHE/priv/HASH/APP-VSN/priv` (read-only files; the executables stay
  executable), and `code:priv_dir(APP)` is then that directory. In a
  release, the boot script runs the copy after the start of `stdlib`,
  before the other applications start (`beam_com_script:extract/1`).
  The code stays in the zip. `HASH` is from the files, so a new build
  gets a new directory, and the next starts use the copy.

**erl mode.** A program that starts a new Erlang VM (a peer node, a
worker in a sandbox) can start its own file: each program has
`-beam_com_exe PATH` (`init:get_argument(beam_com_exe)`), the path of
its file. When the file is started with `BEAM_COM_ERL=1` in the
environment, or through a link named `erl`, all the arguments are for
`erl`, and the VM starts with the `start_clean` boot and the
applications of the zip in the code path, not with the release:

```erlang
{ok, [[Exe]]} = init:get_argument(beam_com_exe),
Port = open_port({spawn_executable, Exe},
                 [{env, [{"BEAM_COM_ERL", "1"}]},
                  {args, ["-noinput", "-eval", "worker:start()"]}]).
```

(`{arg0, "erl"}` is not enough: when the kernel cannot start an APE
file, Cosmopolitan starts it with the APE loader, which gives the path
of the file as `argv[0]`.)

[`examples/toolbox`](../examples/toolbox) shows the three: its `main/1`
comes from `rebar.config`, it runs a shell script from `priv`, and it
starts itself again as `erl`.

## A native file for one system (`--target`)

`--target TARGET` writes a file for one system instead of an APE file,
as Cosmopolitan's `assimilate` does. `TARGET` is a target triple, as for
`deno compile --target` and Rust (or the shorter name of Zig):

| `TARGET` | Short name | System |
|---|---|---|
| `x86_64-unknown-linux-gnu` | `x86_64-linux` | Linux, x86_64 |
| `aarch64-unknown-linux-gnu` | `aarch64-linux` | Linux, aarch64 |
| `x86_64-unknown-freebsd` | `x86_64-freebsd` | FreeBSD, x86_64 |
| `x86_64-apple-darwin` | `x86_64-macos` | macOS, Intel |

```sh
beam.com hello.erl --target x86_64-linux -o hello
./hello
```

Without `--target`, the file is an APE file for all the systems.

The kernel starts the native file directly: no shell script at the
start, no APE loader in `$TMPDIR` or `$HOME`, and on macOS a Mach-O file
that can be signed. The file is the APE file with the ELF or Mach-O
header of the target at its start (the shell script of the APE file
has these headers). The size and the zip do not change, and the file
still runs its release from `/zip`. The builder gives the same bytes as
`assimilate` (tested with the fat `beam.com`), with one change for
x86_64 ELF files (`x86_64-linux` and `x86_64-freebsd`):

- In the APE file, the first `PT_LOAD` segment (the code) starts at the
  file offset 0x10000, after the shell script.
- Rosetta of Apple (for example in a Linux container of `container --arch
  amd64` on Apple Silicon) refuses such a file: `first load segment not
  at file offset 0`.
- So the builder starts that segment at the offset 0, and at an address
  that is lower by 0x10000. The head of the file then maps below the
  code. The code, its addresses and the other segments do not change.

A file of `--assimilate` does not have this change. Under Rosetta, use a
file of `--target x86_64-linux`, or the APE file itself: its APE loader
can be read under Rosetta too (C49 of docs/UPSTREAM.md). A loader that
an older APE file wrote to `~/.ape-1.10` stays there, so remove it once.

The file runs only on its target. Apple Silicon has no native form:
there, APE files run with the APE loader. On Windows, the APE file is
already a native PE file.

The new file is a copy of the file that builds it. So build with the
APE file of `beam.com` (or a copy of it, such as `beam.exe`). A native
file, made with `--target` or with `--assimilate`, gives only native
files:

- Without `--target`, a build (`-o`) stops with an error: the program would
  run only on this system, and you did not ask for that. For example:
  `beam-elf.com: this is a native file (ELF, x86_64), not an APE file:
  a program built from it runs only on this system. Build with the APE
  file of beam.com, or give --target to make a native file`.
- With a `--target` of the same CPU and format (for example
  `x86_64-linux` from an assimilated file on Linux x86_64), the build
  writes a native file for that target.
- With another `--target`, the build stops with an error.

`BEAM_COM_BASE` names the file that a build copies, in place of the file
that runs. So a native file can still make APE files: give it the APE
file that it came from. The two files must have the same zip, else the
build stops. For example, `pages-app.yml` runs an assimilated `beam.com`
(Mix needs a program of the runner), and gives the APE file as
`BEAM_COM_BASE`.

## Distributed Erlang and remote shells

Distributed Erlang works as with `erl`: the flags `-sname`, `-name` and
`-remsh` turn it on, and only then the file starts `epmd` (it is in the
file too, as `erlexec` starts it: `epmd -daemon`, unless `-start_epmd
false`). Without these flags, no `epmd` starts and no port is opened.

`beam.com` takes the flags of `erl`, so it is also the client:

```sh
beam.com -sname dev                              # a shell in a new node
beam.com -sname me -setcookie SECRET -remsh app  # a shell in the node app
beam.com epmd -names                             # the nodes on this computer
```

A program whose release has a node name (`-sname` or `-name` in
`config/vm.args`) has the `remote` command of the scripts of rebar3 and
`mix release`: a shell in the running node, with the cookie of the same
`vm.args`. There you can inspect the node and load new code into it (for
example `c:l(Module)`, or `code:load_binary/3`):

```sh
beam.com examples/counter -o counter.com   # config/vm.args: -sname counter
./counter.com &
./counter.com remote
(counter@host)1> counter:incr().
```

As in every remote shell, `halt()` there stops the node of the program;
leave the shell with Ctrl-G then `q`, or with Ctrl-C two times.

The graphical `observer` needs `wx`, which is not in `beam.com`; start
it in an Erlang installation and connect to the node, or use the shell.

## New code in a running program

A program loads new code when a new file takes the place of its file.
You do not send the full file again: put only the changed files into it
with `zip`, on the server. The program loads each changed module, and
its processes and their state stay.

> **Caution:** do not write into the file of a running program, for
> example with `cp new.com app.com`, `scp` to the same name, or
> `zip -g`. The program maps its file, and a change in place can stop it
> (`SIGSEGV`). Write a new file and rename it: `zip` does this, and so
> does `mv` of a new file.

The files go into the zip at the paths of the file:
`lib/APP-VSN/ebin/`, `lib/APP-VSN/priv/` and
`releases/VSN/consolidated/` (the protocols of Elixir). The new file of
a build gives these paths. For a project that `beam.com DIR -o FILE`
builds, build the new version in the same way, and take only the
directory of your application from it:

```sh
# On your computer, with the same beam.com as the file on the server.
beam.com . -o new.com
unzip -q new.com 'lib/my_app-*' -d stage
tar -czf code.tgz -C stage lib
scp code.tgz server:/srv/my_app/
# On the server: put the files into the file that runs.
cd /srv/my_app && mkdir -p stage && tar -xzf code.tgz -C stage
(cd stage && zip -qr ../my_app.com lib)
```

For a Phoenix app, `beam.com . -o new.com` makes the release with Mix
("Phoenix in one file" in [`ELIXIR.md`](ELIXIR.md)). Take
`lib/my_app-0.1.0` and `releases/0.1.0/consolidated` from it in the same
way. The release directory of `mix release` (with `include_erts:
false`) has the same paths.

When the source is on the server, build over the file that runs:

```sh
cd /srv/my_app/src && beam.com . -o ../my_app.com
```

The builder writes a new file and renames it into the place of the old
one, as `zip` does, so the program loads the changed code. The builder
strips the compile information and the debug information of the beams,
as `mix release` does, so two builds of the same code almost always give
the same bytes. Files that a step of the build writes with a new time
are an exception: for example `priv/static/cache_manifest.json` of
`phx.digest` in a Phoenix app. Thus only the changed modules and files are new in the
new file. The Elixir compiler can give other bytes for some modules; the
program then loads these modules again, with no change of behavior.
The new file must come from the same `beam.com`, because a new runtime
needs a restart.

[`DEPLOY.md`](DEPLOY.md) has the whole deploy of a Phoenix app: systemd,
the migrations, and a build in CI.

A release is not necessary for the beams. `mix compile` (or `erlc`)
gives the same code, in a directory with no version
(`_build/prod/lib/my_app/ebin`): copy it to `lib/my_app-0.1.0/ebin/`
before `zip`. Source files (`.erl`, `.ex`) do not load: compile them
with the same OTP and Elixir as the file, for example with the same
`beam.com`.

> **Caution:** do not put `releases/VSN/start.boot`, `sys.config` or
> `vm.args` of `mix release` into the file. `beam.com DIR -o FILE`
> changes them when it makes the file.

In one second, the program loads the new code, and its log has the
line `beam.com: loaded the new code of MODULES`. The steps:

1. `zip` writes a new file and renames it into the place of the old
   one. The program keeps the old file open, and `/zip` reads from it,
   as before.
2. Each second, the program compares the inode, the size and the time
   of its file (`-beam_com_exe`). It reads a new file when the file
   stays the same for one more check.
3. It reads the zip of the new file as a plain file, and compares the
   CRC-32 of each entry with the file before.
4. A changed beam loads only when its directory is in the code path of
   the program: a restart reads the code from there. A beam at another
   path (for example `lib/my_app/ebin/` with no version) does not load,
   and the log names it.
5. A module loads only when its code is different (`module_info(md5)`).
   A beam with the same code and other chunks (its docs) does not load
   again, so you can put the whole `ebin` directory into the file.
6. The changed modules load together (`code:atomic_load/1`). A module
   with `-on_load` loads after the others.
7. When a process still runs the old code of a module, the new code
   waits. The program tries again at each check, and it never kills a
   process. Its log names the modules that wait.

### Processes with a new state: the appup

The steps above change the code, not the state of a process. A
`gen_server` keeps its state, so a new state needs the instructions of
OTP. Put `lib/APP-VSN/ebin/APP.appup` into the file with the beams:

```erlang
{"0.1.0",
 [{"0.1.0", [{update, my_server, {advanced, to_map}}]}],
 []}.
```

The release keeps its version in such a deploy, so the entry is for the
version that runs (`0.1.0`), or a regular expression that matches it
(`<<"0\\.1\\..*">>`). The program uses the instructions of an appup
that is new or changed in the new file, one time:

| Instruction | Action |
| --- | --- |
| `{update, Mod, {advanced, Extra}}` | Each process of `Mod` stops (`sys:suspend/2`). The code loads, `Mod:code_change(OldVsn, State, Extra)` runs in each process, and the processes go on. `OldVsn` is the `vsn` attribute of the old code. |
| `{update, Mod}`, `{update, Mod, soft}` | The same, with no `code_change/3`. |
| `{update, Mod, supervisor}` | The supervisors of `Mod` read `init/1` again (the child specifications), and each new child starts. A child keeps its process. A child that `init/1` no longer gives goes on. |
| `{load_module, Mod}`, `{add_module, Mod}` | A load, as with no appup. |
| `{apply, {M, F, A}}` | A call after the load. |

The forms with a timeout, a purge and the dependent modules are the
same. A process of `Mod` is a `gen_server`, a `gen_statem` or a
supervisor whose callback module is `Mod` (the initial call of
`proc_lib`). Another instruction, for example a new application or
`restart_new_emulator`, refuses the whole file: the old code stays, and
the log gives the reason. `examples/reload/upgrade/` has an example.

This is the code change of the release handling of OTP, without
`release_handler`: the program does not write `releases/RELEASES`, and
it does not add or remove applications.

`{update, Mod, supervisor}` calls `Mod:init/1` with the arguments of the
first start. So it gives new children only to a supervisor module with
its own `init/1` (`use Supervisor`). `Supervisor.start_link(children,
opts)` of `MyApp.Application` gives the list as the arguments, and the
code change gets the old list again. For such a supervisor, start the
new child with an `apply`:

```erlang
{apply, {'Elixir.Supervisor', start_child, ['Elixir.MyApp.Supervisor', 'Elixir.MyApp.Cache']}}
```

Stop a child that you removed in the same way, with
`supervisor:terminate_child/2` and `supervisor:delete_child/2`: the
program does not stop running work by itself.

### New files of `priv/`

`/zip` reads the old file, also for `priv/`. When the new file has new
files in `lib/APP-VSN/priv/` of a running application, the program:

1. copies the files of `lib/APP-VSN/` of the new file to the cache
   directory (`BEAM_COM_CACHE`, else the cache directory of the user,
   in `beam.com/reload/PID/`);
2. moves the code path of the application there
   (`code:replace_path/2`), so `code:priv_dir/1` and
   `Application.app_dir/2` give the new files;
3. calls `config_change/3` of the application module, after the new
   code loads;
4. deletes the copy before of that application 60 seconds later: a
   request that found a path in it can still read the file.

A Phoenix app from `mix phx.new` has `config_change/3`: it calls
`Endpoint.config_change/2`, which reads the static manifest again. Thus
`mix phx.digest` and a new file give the new digest names in the pages,
and `Plug.Static` serves the new files. The old digest names stay in
`priv/static` (`phx.digest` keeps them), so an open page keeps its
assets. The program removes its copies when it stops. At its first
check (one interval after its start), it also removes the copies of the
processes that do not run (for example a process that a `kill -9`
stopped): the directories `reload/PID/` of the cache. The start itself
does only a stat and an open of the file, so a program starts as fast
as with no reload.

### What a test showed

A test with Phoenix 1.8 and LiveView 1.2 on Linux:

- `mix phx.digest` and `mix release` took 1.9 seconds. The code and the
  assets of the application were 88 KB, and `zip` took 0.02 seconds.
- The open page showed the new text of its LiveView at its next event,
  with the same count, the same WebSocket and no new page load.
- A new page load got the new digest name of `app.css`, and the new
  file. The old digest name still gave 200.

### A restart

A restart runs the file as it is now: each file that `zip` put into it
is in `/zip`, so the program needs no copy and no appup. A restart also
gives the code that a reload could not give: a module that still waited,
a beam outside the code path, or a `code_change/3` that failed. The
appup does not run at a restart, because each process starts with a new
state.

### What needs a restart

- Another runtime: the bytes before the zip changed (the emulator, the
  NIFs in it). The program loads no module, and its log tells it.
- A file that is not a beam, an appup or a file of `priv/` of a running
  application. The log names each one.
- A new application, a new dependency, the configuration, or a NIF.

Erlang keeps two versions of a module. A process that still runs the
oldest version stops the next load of that module, until the process
calls the new code (the load waits; the process does not stop).

### Settings

- `BEAM_COM_RELOAD=MS` is the time between two checks (1000 when not
  set). `BEAM_COM_RELOAD=0` turns the reload off. `-beam_com_reload MS`
  in the `vm.args` of the release does the same.
- In a remote shell (`app.com remote`), `beam_com_reload:status()` gives
  the last result and the modules that wait, and
  `beam_com_reload:check()` checks the file now.
- Each program has `lib/beam_com_reload/` (`src/beam_com_reload`), also a
  release with its own `kernel` (see "Add your release"). `beam.com`
  starts it after the boot, under `kernel_safe_sup`: an error of it never
  stops the program. It needs no change of OTP.
- Not on Windows: a running `.exe` cannot get a new file in its place.
  Not in the WebAssembly runtime (`WORKERS.md`).

[`examples/reload`](../examples/reload) shows each case, and CI runs its
`check.sh` on Linux.

## Add your release

Make a normal OTP release **without ERTS**, for OTP 29, and add its
`releases` and `lib` directories to a copy of `beam.com`:

```sh
cd examples/greeter
rebar3 release                      # include_erts is false in rebar.config
cd _build/default/rel/greeter
cp /path/to/beam.com greeter.com
zip -r greeter.com releases lib
sh ./greeter.com                    # on Windows: rename to greeter.exe
```

CI builds `examples/greeter` in this way, with rebar3, and runs it on
each platform.

When BEAM.com starts, it reads `/zip/releases/start_erl.data`
(`ERTS_VSN REL_VSN`, written by rebar3/relx and by `systools`), and boots
the release like its start script does:

| File in the zip | Use |
| --- | --- |
| `releases/REL_VSN/start.boot` | `-boot`. Its code paths must start with `$ROOT` (rebar3 does this). |
| `releases/REL_VSN/sys.config` | `-config`, if the file is there. |
| `releases/REL_VSN/vm.args` | More flags, if the file is there. `#` starts a comment. Quotes and `-args_file` are not supported. |
| `lib/APP-VSN/ebin/*` | The code of the applications, `kernel` and `stdlib` too. |
| `.args` | Optional. More arguments, one on each line (redbean style). |

Other rules:

- The command line arguments are plain arguments for the program
  (`init:get_plain_arguments/0`). If `.args` has a `...` line, the command
  line arguments go there instead, as flags.
- `ERL_FLAGS` adds flags, as with `erl`. An argument that starts with `+`
  is an emulator flag (`+S 2` becomes `-S 2` before the first `--`).
- Without `-noshell` in `vm.args`, the release starts with a shell
  (like `console`).
- Set `BEAM_COM_VERBOSE=1` to see the full emulator command line.
- When the zip has no release and no `.args`, `beam.com` is a plain
  `beam.smp`.

## Debugging

- `BEAM_COM_VERBOSE=1` shows the arguments that BEAM.com gives ERTS.
- The Cosmopolitan runtime flags work before all other arguments, on
  every platform: `beam.com --strace --version` logs each system call
  (also on Windows and macOS), and `--ftrace` logs each C function
  call. The log goes to standard error.
- Crash reports: when the emulator dies on a fatal signal (for
  example `SIGSEGV`, or `SIGABRT` from `erlang:halt(abort)`), the
  Cosmopolitan runtime prints the signal, the registers and a backtrace
  with function names (from the symbol tables in the zip) to standard
  error, and the exit status is 128 + the signal number.
  `BEAM_COM_CRASH_REPORTS=0` turns this off. Signals that ERTS handles
  itself (`SIGINT`, `SIGUSR1`, `SIGTERM`, ...) do not change.
