defmodule PhoenixDemo.Counters do
  @moduledoc """
  Named counters in the database. On Cloudflare, the database is the SQLite
  storage of the Durable Object, so a counter stays when the VM stops.
  """

  import Ecto.Query
  alias PhoenixDemo.Counters.Counter
  alias PhoenixDemo.Repo

  @doc "Gives the value of a counter. A counter that does not exist is 0."
  @spec get(String.t()) :: non_neg_integer()
  def get(name) do
    Repo.one(from c in Counter, where: c.name == ^name, select: c.value) || 0
  end

  @doc "Adds 1 to a counter, and gives the new value."
  @spec increment(String.t()) :: pos_integer()
  def increment(name) do
    Repo.insert!(%Counter{name: name, value: 1},
      on_conflict: [inc: [value: 1]],
      conflict_target: :name
    )

    get(name)
  end
end
