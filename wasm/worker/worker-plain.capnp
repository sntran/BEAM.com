# workerd configuration of a release as a plain Worker (build.sh with
# MODE=plain): no Durable Object, one VM for each isolate.
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
  # The VM of the isolate serves all requests: a later request resolves the
  # promises of an earlier one.
  compatibilityFlags = ["no_handle_cross_request_promise_resolution"],
  globalOutbound = "net",
  bindings = [
    (name = "PHX_HOST", text = "localhost"),
    (name = "SECRET_KEY_BASE", text = "@SECRET_KEY_BASE@"),
  ],
);
