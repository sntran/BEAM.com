defmodule GreeterEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Task, &GreeterEx.run/0}]
    Supervisor.start_link(children, strategy: :one_for_one, name: GreeterEx.Supervisor)
  end
end
