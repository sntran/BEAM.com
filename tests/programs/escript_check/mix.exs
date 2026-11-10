# A command line Mix project (escript main_module) with
# config/runtime.exs: the builder of a plain Mix project makes the
# program, and the program runs EscriptCheck.main/1 with its arguments.
# The program does not read config/runtime.exs. It has no deps, so the
# build needs no network.
defmodule EscriptCheck.MixProject do
  use Mix.Project

  def project do
    [app: :escript_check, version: "0.1.0", deps: [], escript: [main_module: EscriptCheck]]
  end
end
