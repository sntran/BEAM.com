# Contributing to BEAM.com

Thank you for your help. Bug reports, fixes, tests and documentation are
all welcome.

## Before you start

- For a bug, open an issue with the form that fits: a program that does
  not run correctly, or a build that fails. Give the system, the version
  (`beam.com --version`) and the smallest input that shows the problem.
- For a new feature, read [`docs/ROADMAP.md`](docs/ROADMAP.md) first, and
  open an issue before a large change.
- For a problem of Cosmopolitan, OTP, Emscripten or another project,
  read [`docs/UPSTREAM.md`](docs/UPSTREAM.md): it can be known already.
- For a security problem, see [`SECURITY.md`](SECURITY.md). Do not open
  a public issue.

## Build and test

See [`docs/BUILDING.md`](docs/BUILDING.md) and
[`docs/TESTING.md`](docs/TESTING.md). In short, on Linux x86_64:

```sh
make toolchain               # cosmocc, with its GNU make
build/cosmocc/bin/make       # all the steps: build/beam.com
build/cosmocc/bin/make unit  # the tests of the Mix project, with coverage
tests/run.sh build           # the behavior tests
```

CI runs the tests on each system for each pull request. A change of the
docs only starts no run.

For tests on a system that you do not have, for example macOS or Windows,
use SSH to a runner of CI:

1. Make a key, one time:
   `beam.com -a ssh scripts/remote_ssh.erl -- keygen ~/.ssh/beam_com_ci`.
2. Start the workflow "Remote SSH" (`.github/workflows/remote-ssh.yml`)
   by hand, with the runner, the line of `~/.ssh/beam_com_ci.pub`, and a
   branch `debug/...`.
3. When the branch exists, run commands and copy files:

```sh
scripts/remote_ssh_client.sh debug/ssh ~/.ssh/beam_com_ci exec 'uname -a'
scripts/remote_ssh_client.sh debug/ssh ~/.ssh/beam_com_ci put beam.com beam.com
scripts/remote_ssh_client.sh debug/ssh ~/.ssh/beam_com_ci get out.log out.log
scripts/remote_ssh_client.sh debug/ssh - bridge 2222   # for OpenSSH: ssh -p 2222 runner@127.0.0.1
```

The server is Erlang `:ssh` (`scripts/remote_ssh.erl`) behind a
WebSocket and a quick tunnel of Cloudflare, so the client needs only
HTTPS (also through `HTTPS_PROXY`). Each command runs with bash in a work
directory that stays between the commands. `touch "$REMOTE_SSH_STOP"`
ends the job, and so does the limit of minutes. The job deletes the
branch at its end.

## Rules for a change

- Each change has tests of its behavior, also for errors and limits, not
  only for the normal case.
- Keep each change small, and give it one purpose.
- Keep the code of an Erlang/OTP change in `patches/otp/`, and record a
  problem of another project in `docs/UPSTREAM.md`, with a small
  reproducer.
- Give each patch of another project (in `patches/PROJECT/`) an item in
  `docs/UPSTREAM.md` and a row in `patches/README.md`.
- Update the docs of the behavior that you change.

## The language of the docs

The docs, the code comments, the log text and the commit messages use
[ASD-STE100 Simplified Technical English](https://www.asd-ste100.org/):

- Write short sentences: 20 words or fewer for an instruction, 25 words
  or fewer for a description.
- Use the active voice and the present tense.
- Use one word for one meaning, and the same word in all the files.
- Give one instruction in each sentence, and start it with the verb.
- Do not use the "-ing" form of a verb, except in a technical name.

## License

By a contribution, you agree that it is licensed under the Apache
License 2.0 (see [`LICENSE`](LICENSE)).
