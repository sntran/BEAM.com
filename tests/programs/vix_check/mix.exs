# A check of the NIF of vix (libvips) in a build with EXTRA_NIFS=vix
# (.github/workflows/vix.yml): image operations, and their times.
defmodule VixCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :vix_check,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:vix, "0.42.0"}],
      escript: [main_module: VixCheck]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
