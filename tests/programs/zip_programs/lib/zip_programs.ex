defmodule ZipPrograms do
  @moduledoc """
  Runs the program of priv/bin with the command line arguments, with
  open_port/2 and with System.cmd/3, then stops. Each run writes one line
  "zip_programs: PLACE WAY STATUS LINE (MS ms)": PLACE is priv
  (code:priv_dir/1) or zip (the path in /zip), WAY is port or cmd, STATUS
  is the exit status (or "error" and the reason), LINE is the first line
  of the output that is not empty, and MS is the time of the run.
  """
  use Application

  def start(_type, _args) do
    args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    vsn = Application.spec(:zip_programs, :vsn)
    priv = List.to_string(:code.priv_dir(:zip_programs))

    for {place, dir} <- [priv: priv, zip: "/zip/lib/zip_programs-#{vsn}/priv"] do
      prog = program(dir)
      IO.puts("zip_programs: #{place} port #{timed(fn -> port(prog, args) end)}")
      IO.puts("zip_programs: #{place} cmd #{timed(fn -> cmd(prog, args) end)}")
    end

    System.halt(0)
  end

  defp timed(fun) do
    {us, text} = :timer.tc(fun)
    "#{text} (#{div(us, 1000)} ms)"
  end

  defp program(dir) do
    bin = Path.join(dir, "bin")
    [name | _] = Enum.sort(File.ls!(bin))
    Path.join(bin, name)
  end

  defp port(prog, args) do
    port = Port.open({:spawn_executable, prog}, [:binary, :exit_status, args: args])
    collect(port, "")
  rescue
    e in ErlangError -> "error #{inspect(e.original)}"
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> "#{status} #{first(acc)}"
    after
      60_000 -> "error timeout #{first(acc)}"
    end
  end

  defp cmd(prog, args) do
    {out, status} = System.cmd(prog, args)
    "#{status} #{first(out)}"
  rescue
    e in ErlangError -> "error #{inspect(e.original)}"
  end

  defp first(text) do
    text |> String.split(~r/\r?\n/) |> Enum.find("", &(String.trim(&1) != "")) |> String.trim()
  end
end
