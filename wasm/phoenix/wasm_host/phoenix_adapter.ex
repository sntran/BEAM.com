defmodule WasmHost.PhoenixAdapter do
  @moduledoc """
  A Phoenix endpoint adapter for the WebAssembly emulator: the JavaScript
  host (Node.js, or a Durable Object of Cloudflare Workers) gets the HTTP
  requests and WebSocket frames, and gives them to Erlang through the
  `wasm_host` NIF. In place of `Bandit.PhoenixAdapter`:

      config :hello, HelloWeb.Endpoint, adapter: WasmHost.PhoenixAdapter
  """

  def child_specs(endpoint, _config) do
    [Supervisor.child_spec({WasmHost.Server, plug: endpoint}, id: {endpoint, :wasm_host})]
  end

  def server_info(_endpoint, _scheme), do: {:ok, {{127, 0, 0, 1}, 0}}
end
