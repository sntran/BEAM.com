defmodule Studio.Console do
  @moduledoc """
  The IEx tab of the studio: it evaluates one expression, as IEx does, with
  the bindings of the last expressions. The app of the project runs in the
  same VM, so the expression can call it.
  """

  @timeout 30_000

  @doc "Evaluates CODE. It gives {output, binding}: the text to show and the new bindings."
  def eval(code, binding) do
    {:ok, io} = StringIO.open("")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), io)

        result =
          try do
            {value, binding} = Code.eval_string(code, binding, file: "iex")
            {:ok, inspect(value, pretty: true, limit: 200, width: 100), binding}
          rescue
            e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
          catch
            kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
          end

        send(parent, {self(), result})
      end)

    result =
      receive do
        {^pid, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, _, reason} ->
          {:error, "** (EXIT) " <> inspect(reason)}
      after
        @timeout ->
          Process.exit(pid, :kill)
          {:error, "** (timeout) the expression ran more than #{div(@timeout, 1000)} s"}
      end

    {_, output} = StringIO.contents(io)
    StringIO.close(io)

    case result do
      {:ok, value, binding} -> {output <> value, binding}
      {:error, text} -> {output <> String.trim_trailing(text), binding}
    end
  end
end
