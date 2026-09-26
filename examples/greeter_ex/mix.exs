# An example Mix project for "beam.com build": Elixir code, a Hex package
# written in Elixir (jason) and config/config.exs. beam.com reads this
# file with Mix; the Mix tool itself is not needed.
defmodule GreeterEx.MixProject do
  use Mix.Project

  def project do
    [app: :greeter_ex, version: "1.0.0", elixir: "~> 1.18", deps: deps()]
  end

  def application do
    [mod: {GreeterEx.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [{:jason, "~> 1.4"},
     {:ex_doc, "~> 0.30", only: :dev}]
  end
end
