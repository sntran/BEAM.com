# workerd configuration of a runtime Worker that boots the release of another
# Worker (app.js, a service binding APP): the runtime has no application.
# Put worker.js, beam.mjs, beam.wasm, app.js and release.bin in one directory.
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .runtime),
    (name = "app", worker = .app),
    (name = "net", network = (allow = ["public", "private", "local"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8789", http = (), service = "main") ],
);

const runtime :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "beam.mjs", esModule = embed "beam.mjs"),
    (name = "beam.wasm", wasm = embed "beam.wasm"),
  ],
  compatibilityDate = "2026-09-01",
  compatibilityFlags = ["no_handle_cross_request_promise_resolution"],
  globalOutbound = "net",
  bindings = [
    (name = "APP", service = "app"),
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
