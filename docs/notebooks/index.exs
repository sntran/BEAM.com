# The documentation of beam.com as the Learn section of its Livebook
# (wasm/livebook/setup.sh runs build.exs, which makes a notebook of each
# source). A source is a Markdown page of the repository or a notebook of
# this directory:
#
# - :slug is the path of the notebook in Livebook (/learn/notebooks/SLUG);
# - a notebook with :description and :cover has a card on the Learn page
#   (the first one has the large card); the others are in a :group;
# - :files are files of files/ that the notebook reads (Kino.FS);
# - a code block of a Markdown page is text in Livebook, unless the line
#   before it is "<!-- run -->".
%{
  notebooks: [
    %{
      source: "README.md",
      slug: "beam-com",
      description: "Erlang/OTP and Elixir in one file that runs on six systems, and on Cloudflare, Deno and in this page.",
      cover: "beam.svg"
    },
    %{
      source: "docs/notebooks/tour_of_beam_com.livemd",
      slug: "tour-of-beam-com",
      description: "Processes, messages, supervisors and code that changes while it runs, in BEAM compiled to WebAssembly.",
      cover: "tour.svg"
    },
    %{
      source: "docs/notebooks/phx_new_studio.livemd",
      slug: "phx-new-studio",
      description: "mix phx.new and a Phoenix app with nothing to install: how the studio compiles and runs a project in the VM.",
      cover: "phx.svg"
    },
    %{
      source: "docs/notebooks/erlang_shell.livemd",
      slug: "erlang-shell",
      description: "The Erlang shell and IEx in a terminal in this page, with the VM of this Livebook.",
      cover: "shell.svg"
    },
    %{
      source: "docs/notebooks/inside_the_webassembly_vm.livemd",
      slug: "inside-the-webassembly-vm",
      description: "The threads, the scheduler, the memory, the clock, the files and the snapshots of the runtime.",
      cover: "inside.svg"
    },
    %{
      source: "docs/notebooks/anatomy_of_beam_com.livemd",
      slug: "anatomy-of-beam-com",
      description: "One file that is a shell script, a Windows program, an ELF program and a zip.",
      cover: "anatomy.svg",
      files: ["beam-com-head.bin", "beam-com-zip.etf"]
    },
    %{
      source: "docs/notebooks/webassembly_programs.livemd",
      slug: "webassembly-programs",
      description: "Run WebAssembly: a module in WebAssembly text, and a C program with WASI.",
      cover: "wasm.svg",
      files: ["hello.wasm", "hello.c"]
    },
    %{
      source: "docs/notebooks/hosts_and_storage.livemd",
      slug: "hosts-and-storage",
      description: "One build for Cloudflare Workers, Deno and a web page, and SQL with SQLite in the VM.",
      cover: "hosts.svg"
    },
    %{
      source: "docs/notebooks/networking_at_the_edge.livemd",
      slug: "networking-at-the-edge",
      description: "Outgoing connections, BEAM_CONNECT, incoming requests and distributed Erlang.",
      cover: "networking.svg"
    },
    %{
      source: "docs/notebooks/building_programs.livemd",
      slug: "building-programs",
      description: "The command line of beam.com, and the release that runs this Livebook.",
      cover: "building.svg"
    },
    %{source: "docs/PROGRAMS.md", slug: "programs", group: :guides},
    %{source: "docs/ELIXIR.md", slug: "elixir", group: :guides},
    %{source: "docs/WORKERS.md", slug: "workers", group: :guides},
    %{source: "docs/NOTEBOOKS.md", slug: "notebooks", group: :guides},
    %{source: "docs/LIBRARIES.md", slug: "libraries", group: :guides},
    %{source: "docs/NIFS.md", slug: "nifs", group: :guides},
    %{source: "docs/SANDBOX.md", slug: "sandbox", group: :guides},
    %{source: "docs/PLATFORMS.md", slug: "platforms", group: :reference},
    %{source: "docs/INTERNALS.md", slug: "internals", group: :reference},
    %{source: "docs/JIT.md", slug: "jit", group: :reference},
    %{source: "docs/BENCHMARKS.md", slug: "benchmarks", group: :reference},
    %{source: "docs/UPSTREAM.md", slug: "upstream", group: :reference},
    %{source: "docs/BUILDING.md", slug: "building", group: :project},
    %{source: "docs/TESTING.md", slug: "testing", group: :project},
    %{source: "docs/ROADMAP.md", slug: "roadmap", group: :project},
    %{source: "CONTRIBUTING.md", slug: "contributing", group: :project},
    %{source: "SECURITY.md", slug: "security", group: :project},
    %{source: "docs/history/WASM-LOG.md", slug: "wasm-log", group: :history},
    %{source: "docs/history/JIT-DESIGN.md", slug: "jit-design", group: :history}
  ],
  groups: [
    %{
      id: :guides,
      title: "Guides",
      description: "Run and build programs, Elixir and Phoenix, Cloudflare Workers and Deno, these notebooks, libraries, NIF libraries in WebAssembly, and the sandbox.",
      cover: "guides.svg"
    },
    %{
      id: :reference,
      title: "Reference",
      description: "The platforms, how the file works, the JIT, the measurements, and the changes that other projects need.",
      cover: "reference.svg"
    },
    %{
      id: :project,
      title: "The project",
      description: "How beam.com is built and tested, what comes next, and how to help.",
      cover: "project.svg"
    },
    %{
      id: :history,
      title: "History",
      description: "The records of the WebAssembly runtime and of the JIT, with all the measurements.",
      cover: "history.svg"
    }
  ]
}
