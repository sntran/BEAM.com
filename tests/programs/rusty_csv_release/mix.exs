# A Mix release with the NIF of rusty_csv in a build with
# EXTRA_NIFS=rusty_csv (.github/workflows/rust.yml): the release must boot
# (issue 147). Its application parses two lines of CSV at its start,
# writes the rows, and stops the VM.
defmodule RustyCsvRelease.MixProject do
  use Mix.Project

  def project do
    [
      app: :rusty_csv_release,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:rusty_csv, "0.4.6"}],
      releases: [rusty_csv_release: [include_erts: false]]
    ]
  end

  def application, do: [mod: {RustyCsvRelease, []}, extra_applications: [:logger]]
end
