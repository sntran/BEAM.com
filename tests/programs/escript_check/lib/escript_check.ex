defmodule EscriptCheck do
  @moduledoc "Writes its arguments and the greeting of the config."

  def main(args) do
    IO.puts("escript_check: args #{inspect(args)}")
    IO.puts("escript_check: greeting #{Application.get_env(:escript_check, :greeting, "none")}")
  end
end
