# Notebooks

The documentation of beam.com is a set of notebooks that run. The site
<https://sntran.github.io/BEAM.com/> is Livebook in your browser:
Livebook, Elixir and Erlang/OTP run in the tab, in the WebAssembly
runtime of beam.com, and no server runs your code. Its Learn section has
the notebooks below, and each page of the documentation (this page too)
in the groups Guides, Reference, The project and History.

The page needs a browser with JSPI (Chrome or Edge 137 or later). In
another browser, or in a second tab, the site shows the same pages as
static pages, at [`docs/`](https://sntran.github.io/BEAM.com/docs/).

| Notebook | What it shows | |
|---|---|---|
| A tour of beam.com | Processes, messages, supervisors, and code that changes while it runs. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/tour-of-beam-com) · [source](notebooks/tour_of_beam_com.livemd) |
| How the phx.new studio works | `mix phx.new` in the VM: the compile, one plug in front of the app, JavaScript with no esbuild, and Tailwind in the browser. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/phx-new-studio) · [source](notebooks/phx_new_studio.livemd) |
| The Erlang shell | The Erlang shell and IEx in a terminal in the page, with the VM of Livebook. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/erlang-shell) · [source](notebooks/erlang_shell.livemd) |
| Inside the WebAssembly VM | The threads, the scheduler, the memory, the clock, the files and the snapshots of the runtime. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/inside-the-webassembly-vm) · [source](notebooks/inside_the_webassembly_vm.livemd) |
| The anatomy of beam.com | The file as a shell script, a PE program, ELF programs, a Mach-O program and a zip, read with Elixir. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/anatomy-of-beam-com) · [source](notebooks/anatomy_of_beam_com.livemd) |
| WebAssembly programs | A module in WebAssembly text, with an assembler in Elixir, and a C program with WASI. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/webassembly-programs) · [source](notebooks/webassembly_programs.livemd) |
| Hosts and storage | One build for Cloudflare Workers, Deno and a web page, and a SQL console on SQLite in the VM. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/hosts-and-storage) · [source](notebooks/hosts_and_storage.livemd) |
| Networking at the edge | Outgoing connections, `BEAM_CONNECT`, incoming requests and distributed Erlang. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/networking-at-the-edge) · [source](notebooks/networking_at_the_edge.livemd) |
| Building programs with beam.com | The command line of beam.com, and the release that runs the Livebook. | [Run in your browser](https://sntran.github.io/BEAM.com/#/learn/notebooks/building-programs) · [source](notebooks/building_programs.livemd) |

The same notebooks are in the Learn section of the Livebook of beam.com
on Cloudflare (<https://livebook.fifo.workers.dev>, an instance for each
visitor) and on Deno Deploy (<https://livebook.one.deno.net>). There, a
notebook can also connect to the hosts that `BEAM_CONNECT` allows. On
Cloudflare, a Worker cannot compile WebAssembly, so the notebook
"WebAssembly programs" runs only in the page and on Deno.

## How the pages become notebooks

[`docs/notebooks/build.exs`](notebooks/build.exs) makes the notebooks
from the sources that [`docs/notebooks/index.exs`](notebooks/index.exs)
names, in its order:

- A `.livemd` file of `docs/notebooks/` is a notebook, with a card on
  the Learn page.
- A Markdown page of the repository is a notebook in a group. A code
  block of Elixir or Erlang in a Markdown page stays text, because most
  of them are commands for a terminal. To make a code block a cell that
  runs, put the line `<!-- run -->` before it.
- A link to another source goes to its notebook, and a link to another
  file of the repository goes to GitHub.

[`wasm/livebook/setup.sh`](../wasm/livebook/setup.sh) runs `build.exs`,
and [`livebook.patch`](../wasm/livebook/livebook.patch) makes the Learn
section show only these notebooks and groups. The patch also opens a
Learn notebook for a link `SLUG.livemd`. The address of a notebook is
`#/learn/notebooks/SLUG` at the root of the site.
[`docs/site/prepare.exs`](site/prepare.exs) makes the static pages from
the same sources, each with a link to its notebook.

## Add a notebook

1. Write the notebook in `docs/notebooks/`, as a `.livemd` file. Write
   its text in ASD-STE100 Simplified Technical English (see
   [`CONTRIBUTING.md`](../CONTRIBUTING.md)). Link to other pages with
   their paths in the repository, such as `../WORKERS.md`.
2. Add it to [`docs/notebooks/index.exs`](notebooks/index.exs), with the
   text of its card and a cover (an SVG file of 200 × 120). Put the files
   that it reads (with `Kino.FS.file_path/1`) in `docs/notebooks/files/`,
   name them in `files:`, and name them in the `file_entries` of the
   notebook.
3. Test it in the page: build Livebook with
   [`wasm/livebook/setup.sh`](../wasm/livebook/setup.sh), make the site
   with [`docs/site.sh`](site.sh), and serve it on a local server. Run
   all its cells (<kbd>Esc</kbd>, then <kbd>e</kbd> and <kbd>a</kbd>).
