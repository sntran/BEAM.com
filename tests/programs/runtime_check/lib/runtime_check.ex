defmodule RuntimeCheck do
  @moduledoc "Writes the config of config/runtime.exs, then stops the program."
  use Application

  def start(_type, _args) do
    IO.puts("runtime_check: #{Application.fetch_env!(:runtime_check, :greeting)}")
    IO.puts("runtime_check: build #{Application.fetch_env!(:runtime_check, :build)}")
    System.halt(0)
  end
end
