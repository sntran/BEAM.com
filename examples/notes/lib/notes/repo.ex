defmodule Notes.Repo do
  use Ecto.Repo, otp_app: :notes, adapter: Ecto.Adapters.SQLite3
end

defmodule Notes.Note do
  use Ecto.Schema

  schema "notes" do
    field :text, :string
    field :data, :binary
    timestamps()
  end
end

defmodule Notes.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :text, :string
      add :data, :binary
      timestamps()
    end
  end
end
