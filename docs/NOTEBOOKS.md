# Notebooks

These notebooks are documentation of beam.com that runs. Open one in
your browser: Livebook, Elixir and Erlang/OTP run in the tab, in the
WebAssembly runtime of beam.com, and no server runs your code. The page
needs a browser with JSPI (Chrome or Edge 137 or later).

| Notebook | What it shows | |
|---|---|---|
| A tour of beam.com | Processes, messages, supervisors, and code that changes while it runs. | [Run in your browser](https://sntran.github.io/BEAM.com/livebook/#/learn/notebooks/tour-of-beam-com) · [source](notebooks/tour_of_beam_com.livemd) |
| Inside the WebAssembly VM | The threads, the scheduler, the memory, the clock, the files and the snapshots of the runtime. | [Run in your browser](https://sntran.github.io/BEAM.com/livebook/#/learn/notebooks/inside-the-webassembly-vm) · [source](notebooks/inside_the_webassembly_vm.livemd) |
| Hosts and storage | One build for Cloudflare Workers, Deno and a web page, and SQLite in the VM. | [Run in your browser](https://sntran.github.io/BEAM.com/livebook/#/learn/notebooks/hosts-and-storage) · [source](notebooks/hosts_and_storage.livemd) |
| Networking at the edge | Outgoing connections, `BEAM_CONNECT`, incoming requests and distributed Erlang. | [Run in your browser](https://sntran.github.io/BEAM.com/livebook/#/learn/notebooks/networking-at-the-edge) · [source](notebooks/networking_at_the_edge.livemd) |
| Building programs with beam.com | The command line of beam.com, and the release that runs the Livebook. | [Run in your browser](https://sntran.github.io/BEAM.com/livebook/#/learn/notebooks/building-programs) · [source](notebooks/building_programs.livemd) |

The same notebooks are in the Learn section of the Livebook of beam.com
on Cloudflare (<https://livebook.fifo.workers.dev>). There, a notebook
can also connect to the internet.

## Add a notebook

1. Write the notebook in `docs/notebooks/`, as a `.livemd` file. Write
   its text in ASD-STE100 Simplified Technical English (see
   [`CONTRIBUTING.md`](../CONTRIBUTING.md)).
2. Add it to [`docs/notebooks/index.exs`](notebooks/index.exs), with the
   text of its card and a cover (an SVG file of 200 × 120).
3. Test it in the page: build Livebook with
   [`wasm/livebook/setup.sh`](../wasm/livebook/setup.sh), make the page
   with [`page.sh`](../wasm/livebook/page.sh), and serve it on a local
   server. Run all its cells (<kbd>Esc</kbd>, then <kbd>e</kbd> and
   <kbd>a</kbd>).

`setup.sh` copies `docs/notebooks/` into the Livebook source, and
[`livebook.patch`](../wasm/livebook/livebook.patch) makes the Learn
section show only these notebooks. The link of a notebook in the page is
`livebook/#/learn/notebooks/SLUG`, where SLUG is its file name with `-`
in place of `_`.
