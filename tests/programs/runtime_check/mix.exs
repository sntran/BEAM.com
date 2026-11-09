# A Mix project with config/runtime.exs: beam.com DIR -o FILE makes its
# release with Mix (beam_com_mix), and the program reads the config at
# its start. It has no deps, so the build needs no network.
defmodule RuntimeCheck.MixProject do
  use Mix.Project

  def project, do: [app: :runtime_check, version: "0.1.0", deps: []]

  def application, do: [mod: {RuntimeCheck, []}, extra_applications: [:logger]]
end
