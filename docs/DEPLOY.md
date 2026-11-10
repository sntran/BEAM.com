# Deploy a Phoenix app to a server

This page tells how to put a Phoenix LiveView app on a Linux server as one
file, and how to send new code to it with no restart. The same steps work
for each Erlang or Elixir program that `beam.com DIR -o FILE` builds.

The file runs on Linux x86_64 and aarch64, and the server needs no Erlang,
no Elixir and no Node.js. You can build the file on the server (A) or in CI
(B).

## What you need

- A Linux server with your database, for example PostgreSQL.
- One version of `beam.com`. Use the same version on each computer that
  builds the file. The new code of a file from another version of
  `beam.com` loads only after a restart (see "What needs a restart").
- For the build: the network (Hex, the git deps, and the programs of
  tailwind and esbuild, which `assets.deploy` gets the first time).

Get a fixed version, and check its SHA-256:

```sh
VERSION=v0.1.0      # the version that you use (after 0.1.0-rc.6)
curl -fsSLO "https://github.com/sntran/BEAM.com/releases/download/$VERSION/beam.com"
curl -fsSLO "https://github.com/sntran/BEAM.com/releases/download/$VERSION/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
```

## The program on the server

`beam.com . -o hello.com` makes the file (see "Phoenix in one file" in
[`ELIXIR.md`](ELIXIR.md)). The file reads `config/runtime.exs` at each
start, so it gets its settings from the environment, as a release of Mix.

> **Caution:** put a comment of the environment file on its own line.
> systemd reads `#` as a comment only at the start of a line, so a
> comment after a value becomes a part of the value.

```sh
# /srv/hello/env, with the mode 600
PHX_SERVER=true
PHX_HOST=hello.example.com
PORT=4000
# The output of mix phx.gen.secret:
SECRET_KEY_BASE=...
DATABASE_URL=ecto://USER:PASS@localhost/hello
```

A systemd unit starts it:

```ini
# /etc/systemd/system/hello.service
[Unit]
Description=hello
After=network-online.target

[Service]
User=hello
WorkingDirectory=/srv/hello
EnvironmentFile=/srv/hello/env
ExecStart=/bin/sh /srv/hello/hello.com
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

- `/bin/sh` starts the file on each Linux, also with no `binfmt_misc` for
  APE files.
- The program watches the path of its file (`/srv/hello/hello.com`). A new
  file at this path gives the program its new code.
- The program puts the copies of new `priv/` files in its cache:
  `BEAM_COM_CACHE`, else `~/.cache/beam.com` of the user `hello`.
- The migrations: see "Migrations" below.
- `systemctl stop hello` sends `SIGTERM`, and the program stops as a
  release of Mix does.

### Migrations

The file has no `bin/hello eval`. Run the migrations at the start of the
program with `Ecto.Migrator` in the supervision tree:

- An app of `mix phx.new --database sqlite3` has it.
- An app of `mix phx.new` with PostgreSQL (the default) does not. Add it
  after the repo, as the template of SQLite does:

  ```elixir
  # lib/hello/application.ex
  children = [
    HelloWeb.Telemetry,
    Hello.Repo,
    {Ecto.Migrator,
     repos: Application.fetch_env!(:hello, :ecto_repos), skip: skip_migrations?()},
    # ...
  ]

  # The migrations run in a release only: beam.com sets RELEASE_NAME.
  defp skip_migrations?(), do: System.get_env("RELEASE_NAME") == nil
  ```

The migrator runs at each start, so a new migration needs a restart.

> **Caution:** never write into the file that runs: no `cp`, no `scp` to
> the same name, no `zip -g`. The program maps its file, and a change in
> place can stop it with `SIGSEGV`. Write a new file and rename it into
> place, as below. `beam.com DIR -o FILE`, `zip` and `mv` do this.

## A: build on the server

Put `beam.com` and the source on the server. `curl` writes `beam.com`
with no execute permission, so set it, and put the file in `PATH`:

```sh
chmod +x beam.com
sudo mv beam.com /usr/local/bin/
git clone https://example.com/you/hello.git /srv/hello/src
cd /srv/hello/src && beam.com . -o /srv/hello/hello.com
sudo systemctl enable --now hello
```

For new code, build again over the file that runs:

```sh
cd /srv/hello/src && git pull && beam.com . -o /srv/hello/hello.com
```

- The builder writes a new file and renames it, so the program loads the
  changed modules about one second later. Its processes stay, and so do
  the LiveView sockets and their pages.
- Two builds of the same code almost always give the same bytes, so
  only the changed modules and files are new.
- Mix keeps `deps/` and `_build/` in `/srv/hello/src`, so the second
  build takes seconds.
- For a change that needs a restart, run `sudo systemctl restart hello`
  after the build.

## B: build in CI

CI builds the file, and the server only runs it. The server needs no
build tools. This workflow of GitHub Actions makes `hello.com` as an
artifact:

```yaml
name: Build
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      BEAM_COM: v0.1.0      # the version of the server
    steps:
      - uses: actions/checkout@v4
      - name: beam.com
        run: |
          base=https://github.com/sntran/BEAM.com/releases/download/$BEAM_COM
          curl -fsSLO "$base/beam.com"
          curl -fsSLO "$base/SHA256SUMS"
          sha256sum -c --ignore-missing SHA256SUMS
      - uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ hashFiles('mix.lock') }}
      - run: sh ./beam.com . -o hello.com
      - uses: actions/upload-artifact@v4
        with:
          name: hello.com
          path: hello.com
```

- The runner needs no `git`: with no `git` program, the git deps of an
  `https` or SSH URL come with the git client of `beam.com`.
- The cache keeps the deps, the compiled code, and the programs of
  tailwind and esbuild.
- The file runs on x86_64 and on aarch64, so one build serves both kinds
  of server.

Then send the new code to the server in one of two ways.

### The whole file

This works for each change. Copy the file to a new name, then rename it:

```sh
scp hello.com deploy@server:/srv/hello/hello.com.new
ssh deploy@server 'mv /srv/hello/hello.com.new /srv/hello/hello.com'
```

The program loads the changed modules. For a change that needs a restart,
also run `systemctl restart hello`. A new Phoenix app makes a file of about
40 MB.

### Only the changed code

The code of your app is in `lib/hello-VSN/` of the file (with
`priv/static`), and its protocols are in `releases/VSN/consolidated/`.
When the deps stay the same, these are all the changes. Send only them, a
few MB, and put them into the file on the server with `zip`:

```sh
rm -rf stage && unzip -q hello.com 'lib/hello-*' 'releases/*/consolidated/*' -d stage
tar -czf code.tgz -C stage .
scp code.tgz deploy@server:/srv/hello/
ssh deploy@server 'cd /srv/hello && rm -rf stage && mkdir stage &&
  tar -xzf code.tgz -C stage && (cd stage && zip -qr ../hello.com .)'
```

`zip` writes a new file and renames it into place, so this is safe while
the program runs. Use the same `beam.com` in CI and for the file on the
server. See "New code in a running program" in
[`PROGRAMS.md`](PROGRAMS.md) for the rules of a load.

## What needs a restart

The program loads new code with no restart for:

- each changed module of your app or of a dep, all together;
- an `.appup` with `code_change/3` for a process with a new state;
- new files of `priv/`, such as the digested assets of `phx.digest`.
  Phoenix reads its static manifest again.

These need a restart (`systemctl restart hello`):

- a new dep or a new application;
- a change of the config (`config/runtime.exs`, `config/*.exs`);
- a new migration (the migrator runs at the start);
- a new NIF, or another version of `beam.com`.

The log of the program tells which files of a new file need a restart.
For a restart with almost no failed request, see the spike
[`examples/bluegreen`](../examples/bluegreen).

## Limits, and why

- **Umbrella projects.** The builder does not build an umbrella project,
  and the Mix steps need one application with `:app` in `mix.exs`.
- **Some settings of SSH.** The git client of `beam.com` gets git deps
  over SSH with the keys of `~/.ssh` and of the SSH agent, and checks
  `known_hosts`. `ProxyJump`, `ProxyCommand`, `GIT_SSH_COMMAND` and the
  keys of a FIDO token need the `git` and `ssh` programs, because these
  settings start a program or need a device. See "Git over SSH" in
  [`PROGRAMS.md`](PROGRAMS.md). In CI, put the deploy key in the agent
  (for example with `webfactory/ssh-agent`) and the key of the host in
  `~/.ssh/known_hosts`.
- **A Phoenix app on Windows.** The Mix steps work on Windows (C16 of
  [`UPSTREAM.md`](UPSTREAM.md)). CI builds a new Phoenix app with no
  database (`mix phx.new --no-ecto`) there, and the file serves its
  start page. CI does not test a database or a dep with C code on
  Windows: `elixir_make` needs `make` and a C compiler there. The
  tailwind and esbuild packages choose their Linux programs on Windows,
  because `os:type()` is `{unix, windows}`. Thus the builder gives
  tailwind the target `windows-x64.exe`, and esbuild the path of
  `esbuild.exe` from npm, when your config gives no target and no path.
  The builder checks the signature of npm and the SHA-512 of
  `esbuild.exe`, as the esbuild package does (see "Phoenix in one file"
  in [`ELIXIR.md`](ELIXIR.md)).
- **NIFs.** A package with C code works only when `beam.com` has its NIF
  (see [`NIFS.md`](NIFS.md)).
