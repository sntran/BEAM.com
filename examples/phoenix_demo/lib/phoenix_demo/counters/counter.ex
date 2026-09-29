defmodule PhoenixDemo.Counters.Counter do
  @moduledoc "A named counter in the database."
  use Ecto.Schema

  schema "counters" do
    field :name, :string
    field :value, :integer, default: 0
  end
end
