# New code in a running program

This example shows the reload of new code from the file of a running
program ("New code in a running program" in
[`docs/PROGRAMS.md`](../../docs/PROGRAMS.md)). The program has three
parts:

- `reload_server`: a counter in a `gen_server`. Its state stays when
  its code changes.
- `reload_text`: the text of the version, which changes in each step.
- `reload_loop`: a process whose loop calls itself with a local call. It
  stays in the code that it runs, so the next version of its module
  waits for it.
- `priv/hello.txt`, and `config_change/3` of `reload_app`, which counts
  its calls.
- `upgrade/`: the next `reload_server`, whose state is a map, and the
  appup that changes the state with `code_change/3`.

The program answers one command on each line on `127.0.0.1:RELOAD_PORT`
(`hello`, `state`, `loop`, `move`, `file` and `status`).

```sh
beam.com examples/reload -o reload.com
./reload.com &                                  # version 1
mkdir -p new/lib/reload-1.0.0/ebin              # version 2 of a module
beam.com -noshell -eval 'compile:file("reload_text.erl", [{outdir, "new/lib/reload-1.0.0/ebin"}]), halt().'
(cd new && zip -r ../reload.com lib)            # the program loads it
```

[`check.sh`](check.sh) does it all from end to end, and `tests/run.sh`
runs it on Linux:

```sh
examples/reload/check.sh build/beam.com
```

1. Version 2 of `reload_text` and `reload_loop` loads. `reload_server`
   has the same code with its debug information: it does not load again,
   and its count stays.
2. Version 3 of `reload_loop` waits: the loop still runs version 1, the
   old code.
3. The command `move` makes the loop call the current code (version 2).
   Then version 3 loads.
4. The appup of `upgrade/`: `code_change/3` turns the count of
   `reload_server` into a map, and the count stays.
5. A new `priv/hello.txt`: the application moves to a copy in the cache,
   and `config_change/3` runs one time.
6. A beam at `lib/reload/ebin/` (no version) is not in the code path: it
   does not load.
7. A copy of the file with `BEAM_COM_RELOAD=0` has no reload.
