defmodule Studio.MixProject do
  use Mix.Project

  # The studio: `mix phx.new` and a Phoenix app that you change in the
  # browser. The VM of the studio makes the project with the generator of
  # phx_new, compiles it, and serves it. So the release has the packages that
  # a new project of `mix phx.new --database sqlite3` needs, and Mix.
  def project do
    [
      app: :studio,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The app of the project can implement a protocol for its structs.
      consolidate_protocols: false,
      # RELEASE_ERTS=false: a release with no ERTS, for beam.com.
      releases: [studio: [include_erts: System.get_env("RELEASE_ERTS") != "false"]]
    ]
  end

  def application do
    [
      mod: {Studio.Application, []},
      # :mix and :eex for the generator, :compiler for the compile of the
      # project in the VM.
      extra_applications: [:logger, :runtime_tools, :mix, :eex, :compiler]
    ]
  end

  defp deps do
    [
      {:phx_new, "1.8.15"},
      # The packages of a new project (phx_new 1.8.15).
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end
end
