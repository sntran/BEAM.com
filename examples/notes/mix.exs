# Ecto SQLite (ecto_sqlite3) and Bandit: natively a SQLite file; on
# Cloudflare Workers (--target wasm32) the host runs the SQL (D1, or the
# SQLite storage of a Durable Object). /hash uses bcrypt and argon2, as
# phx.gen.auth does.
#
#   beam.com examples/notes                          # http://localhost:4000/
#   beam.com examples/notes -o notes --target wasm32
defmodule Notes.MixProject do
  use Mix.Project

  def project do
    [app: :notes, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application do
    [mod: {Notes.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ecto_sqlite3, "~> 0.22"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      # Their NIFs are in beam.com: the versions of "beam.com --version".
      {:bcrypt_elixir, "3.3.2"},
      {:argon2_elixir, "4.1.3"}
    ]
  end
end
