using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [ (name = "main", worker = .beam) ],
  sockets = [ (name = "http", address = "127.0.0.1:8788", http = (), service = "main") ],
);
const beam :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "beam.mjs", esModule = embed "beam.mjs"),
    (name = "beam.wasm", wasm = embed "beam.wasm"),
  ],
  compatibilityDate = "2026-09-01",
);
