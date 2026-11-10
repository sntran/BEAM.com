# A Mix project with config/runtime.exs: beam.com DIR -o FILE makes its
# release with Mix, and beam.com --tool mix DIR -o FILE uses the builder
# of a plain Mix project. The tests copy a program to priv/bin of a copy
# of the project (docs/PROGRAMS.md, "priv files as real files"). It has
# no deps, so the build needs no network.
defmodule ZipPrograms.MixProject do
  use Mix.Project

  def project, do: [app: :zip_programs, version: "0.1.0", deps: []]

  def application, do: [mod: {ZipPrograms, []}, extra_applications: [:logger]]
end
