defmodule PhoenixDemo.Repo.Migrations.CreateCounters do
  use Ecto.Migration

  def change do
    create table(:counters) do
      add :name, :string, null: false
      add :value, :integer, null: false, default: 0
    end

    create unique_index(:counters, [:name])
  end
end
