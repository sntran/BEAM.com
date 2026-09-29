# The notebooks of beam.com in the Learn section of its Livebook
# (wasm/livebook/setup.sh copies this directory into Livebook): their
# order, the text of their cards, and their covers.
[
  %{
    file: "tour_of_beam_com.livemd",
    description: "Processes, messages, supervisors and code that changes while it runs, in BEAM compiled to WebAssembly.",
    cover: "tour.svg"
  },
  %{
    file: "inside_the_webassembly_vm.livemd",
    description: "The threads, the scheduler, the memory, the clock, the files and the snapshots of the runtime.",
    cover: "inside.svg"
  },
  %{
    file: "hosts_and_storage.livemd",
    description: "One build for Cloudflare Workers, Deno and a web page, and SQLite in the VM.",
    cover: "hosts.svg"
  },
  %{
    file: "networking_at_the_edge.livemd",
    description: "Outgoing connections, BEAM_CONNECT, incoming requests and distributed Erlang.",
    cover: "networking.svg"
  },
  %{
    file: "building_programs.livemd",
    description: "The command line of beam.com, and the release that runs this Livebook.",
    cover: "building.svg"
  }
]
