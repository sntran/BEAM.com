defmodule BeamCom.HostStandIn do
  @moduledoc """
  A stand-in for the NIF module `:wasm_host` of the WebAssembly runtime,
  for the tests of `src/wasm_host` in the native VM. `send/1` gives each
  message of the VM for the host (a JSON header, a line feed and the
  body) to the process `:wasm_host_stand_in` as `{:host, header, body}`,
  when such a process exists. `select/0` gives `:ok`, and `take/0` gives
  `:empty`.

  The stand-in replaces `:wasm_host` in the VM, so a test module that
  loads it is not async. `load/0` also makes the table `:wasm_host_server`
  of the pump (`:wasm_host_server.register/1`), and `unload/1` removes
  both.
  """

  @name :wasm_host_stand_in

  @doc "The name of the process that gets the messages for the host."
  def name, do: @name

  @doc "Loads the stand-in and makes the table. Gives the owner of the table."
  def load do
    test = self()

    owner =
      spawn(fn ->
        :ets.new(:wasm_host_server, [:named_table, :public])
        send(test, :table)
        receive do: (:stop -> :ok)
      end)

    receive do: (:table -> :ok)

    source = """
    -module(wasm_host).
    -export([send/1, select/0, take/0]).
    send(Data) ->
        [Header, Body] = binary:split(iolist_to_binary(Data), <<"\\n">>),
        case whereis(#{@name}) of
            undefined -> ok;
            Host -> Host ! {host, json:decode(Header), Body}, ok
        end.
    select() -> ok.
    take() -> empty.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
    forms = for f <- split_forms(tokens), do: elem(:erl_parse.parse_form(f), 1)
    {:ok, :wasm_host, bin} = :compile.forms(forms, [:binary])
    :code.purge(:wasm_host)
    {:module, :wasm_host} = :code.load_binary(:wasm_host, ~c"wasm_host_stand_in.erl", bin)
    owner
  end

  @doc "Removes the stand-in and the table of the owner."
  def unload(owner) do
    send(owner, :stop)
    :code.purge(:wasm_host)
    :code.delete(:wasm_host)
  end

  @doc "The caller gets the messages for the host from now on."
  def take_host, do: take_host_for(self())

  @doc "The process pid gets the messages for the host from now on."
  def take_host_for(pid) do
    if Process.whereis(@name), do: Process.unregister(@name)
    Process.register(pid, @name)
    :ok
  end

  defp split_forms(tokens) do
    {forms, []} =
      Enum.reduce(tokens, {[], []}, fn
        {:dot, _} = dot, {forms, form} -> {[Enum.reverse([dot | form]) | forms], []}
        token, {forms, form} -> {forms, [token | form]}
      end)

    Enum.reverse(forms)
  end
end
