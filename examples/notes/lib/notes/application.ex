defmodule Notes.Application do
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4000"))

    children = [
      Notes.Repo,
      # The migrations, before the server: modules (no .exs file to
      # compile at the start).
      %{id: :migrate, start: {__MODULE__, :migrate, []}, restart: :transient},
      {Bandit, plug: Notes.Router, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Notes.Supervisor)
  end

  def migrate do
    Ecto.Migrator.run(Notes.Repo, [{1, Notes.Migrations.CreateNotes}], :up, all: true)
    :ignore
  end
end
