# workerd configuration of a release (build.sh fills it): the Worker, the
# runtime of wasm/erts, and release.bin of pack.erl.
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .app),
    # Outgoing connections (wasm_tcp): also to this computer, for the tests.
    (name = "net", network = (allow = ["public", "private", "local"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8789", http = (), service = "main") ],
);

const app :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "beam.mjs", esModule = embed "beam.mjs"),
    (name = "beam.wasm", wasm = embed "beam.wasm"),
    (name = "release.bin", data = embed "release.bin"),
  ],
  compatibilityDate = "2026-09-01",
  globalOutbound = "net",
  durableObjectNamespaces = [ (className = "Beam", uniqueKey = "beam-release") ],
  durableObjectStorage = (inMemory = void),
  bindings = [
    (name = "BEAM", durableObjectNamespace = "Beam"),
    (name = "PHX_HOST", text = "localhost"),
    (name = "SECRET_KEY_BASE", text = "@SECRET_KEY_BASE@"),
  ],
);
