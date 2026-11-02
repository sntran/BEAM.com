# A check of the NIF of rusty_csv (Rust, Rustler) in a build with
# EXTRA_NIFS=rusty_csv (.github/workflows/rust.yml): parse and dump, and
# their times against NimbleCSV (Elixir).
defmodule RustyCsvCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :rusty_csv_check,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:rusty_csv, "0.4.6"}, {:nimble_csv, "1.3.0"}],
      escript: [main_module: RustyCsvCheck]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
