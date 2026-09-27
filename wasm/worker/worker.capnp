# workerd configuration (build.sh fills it): the BEAM runtime Worker
# (worker.js, beam.mjs, beam.wasm) and a Worker with the release (app.js,
# release.bin of pack.erl), which the runtime reaches with a service binding.
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "beam", worker = .beam),
    (name = "app", worker = .app),
    # Outgoing connections (wasm_tcp): also to this computer, for the tests.
    (name = "net", network = (allow = ["public", "private", "local"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8789", http = (), service = "beam") ],
);

const beam :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "beam.mjs", esModule = embed "beam.mjs"),
    (name = "beam.wasm", wasm = embed "beam.wasm"),
  ],
  compatibilityDate = "2026-09-01",
  # The VM of an isolate serves all its requests: a later request resolves
  # the promises of an earlier one.
  compatibilityFlags = ["no_handle_cross_request_promise_resolution"],
  globalOutbound = "net",
  bindings = [
    (name = "APP", service = "app"),
    # The text bindings are the environment of the release.
    (name = "PHX_HOST", text = "localhost"),
    (name = "SECRET_KEY_BASE", text = "@SECRET_KEY_BASE@"),
  ],
);

const app :Workerd.Worker = (
  modules = [
    (name = "app.js", esModule = embed "app.js"),
    (name = "release.bin", data = embed "release.bin"),
  ],
  compatibilityDate = "2026-09-01",
);
