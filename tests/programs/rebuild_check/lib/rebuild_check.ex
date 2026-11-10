defmodule RebuildCheck do
  @moduledoc "Writes one line, then stops the program."
  use Application

  def start(_type, _args) do
    IO.puts("rebuild_check: v1")
    System.halt(0)
  end
end
