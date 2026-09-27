# workerd configuration of the Phoenix Worker (build-worker.sh fills it).
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .app) ],
  sockets = [ (name = "http", address = "127.0.0.1:8789", http = (), service = "main") ],
);

const app :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "beam.mjs", esModule = embed "beam.mjs"),
    (name = "beam.wasm", wasm = embed "beam.wasm"),
  ],
  compatibilityDate = "2026-09-01",
  durableObjectNamespaces = [ (className = "Beam", uniqueKey = "beam-phoenix-hello") ],
  durableObjectStorage = (inMemory = void),
  bindings = [
    (name = "BEAM", durableObjectNamespace = "Beam"),
    (name = "PHX_HOST", text = "localhost"),
    (name = "RELEASE_VSN", text = "@VSN@"),
    (name = "SECRET_KEY_BASE", text = "@SECRET_KEY_BASE@"),
  ],
);
