defmodule WasmHost.WebSocket do
  @moduledoc """
  The process of a WebSocket connection of the JavaScript host: it runs a
  `WebSock` handler (for example the LiveView socket), with the frames
  from the host and the messages of Erlang.
  """

  def run(id, handler, state, _opts) do
    WasmHost.Server.register(id)
    WasmHost.Server.send_host(%{t: "ws_accept", id: id})
    handle(id, handler, handler.init(state))
  end

  defp loop(id, handler, state) do
    receive do
      {:wasm_host, "ws_msg", meta, data} ->
        opcode = if meta["op"] == "binary", do: :binary, else: :text
        handle(id, handler, handler.handle_in({data, opcode: opcode}, state))

      {:wasm_host, "ws_close", _meta, _} ->
        handler.terminate(:remote, state)
        WasmHost.Server.unregister(id)

      message ->
        handle(id, handler, handler.handle_info(message, state))
    end
  end

  defp handle(id, handler, result) do
    case result do
      {:ok, state} ->
        loop(id, handler, state)

      {:push, frames, state} ->
        push(id, frames)
        loop(id, handler, state)

      {:reply, _status, frames, state} ->
        push(id, frames)
        loop(id, handler, state)

      {:stop, reason, state} ->
        close(id, handler, reason, 1000, state)

      {:stop, reason, detail, state} ->
        close(id, handler, reason, detail, state)

      {:stop, reason, detail, frames, state} ->
        push(id, frames)
        close(id, handler, reason, detail, state)
    end
  end

  defp push(id, frames) do
    for {op, data} <- List.wrap(frames), op in [:text, :binary] do
      WasmHost.Server.send_host(%{t: "ws_send", id: id, op: op}, data)
    end

    :ok
  end

  defp close(id, handler, reason, detail, state) do
    code = case detail do
      {code, _} -> code
      code when is_integer(code) -> code
      _ -> 1000
    end

    WasmHost.Server.send_host(%{t: "ws_close", id: id, code: code})
    WasmHost.Server.unregister(id)
    handler.terminate(if(reason == :normal, do: :normal, else: {:error, reason}), state)
  end
end
