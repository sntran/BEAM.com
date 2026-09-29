# Security

## Report a problem

Report a security problem in private, through a GitHub security
advisory: <https://github.com/sntran/BEAM.com/security/advisories/new>.
Do not open a public issue for it.

Give the version (`beam.com --version`), the system, and the steps that
show the problem.

## What is in scope

- `beam.com` and the programs that it makes: the builder, the runner of
  one-file programs, the sandbox (`--allow-*`), and the Hex client.
- The Workers that `--target wasm32` makes: `worker.js`, `durable.js`
  and the `wasm_host` application.

A problem of Erlang/OTP, Elixir, OpenSSL, SQLite, WAMR or Cosmopolitan
itself goes to that project. BEAM.com takes their fixes in a new release.

## Limits to know

- The sandbox works on Linux and OpenBSD only. On the other systems,
  the `--allow-*` flags have no effect (see
  [`docs/SANDBOX.md`](docs/SANDBOX.md)).
- In a Worker, anyone who can reach the Worker can reach the listeners
  of its program through `/.tcp/PORT`. Protect that path before you
  deploy a listener (see [`docs/WORKERS.md`](docs/WORKERS.md)).
- The public Livebook of `wasm/livebook` and the REPL of
  `examples/worker` run the code of each visitor. Give them no secret,
  and give them `BEAM_CONNECT` (the hosts that the VM can connect to).
  The REPL is a restricted shell with an allowlist of functions, but that
  is no sandbox.
