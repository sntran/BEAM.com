defmodule Studio.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    base = base_path()
    port = String.to_integer(System.get_env("PORT", "4000"))
    root = System.get_env("STUDIO_ROOT") || Path.join(System.tmp_dir!(), "studio")

    # The endpoint of the studio: no server of its own (Studio.Front calls
    # it), under the path of the site, with a secret for each start of the VM.
    endpoint = Application.get_env(:studio, StudioWeb.Endpoint, [])

    Application.put_env(
      :studio,
      StudioWeb.Endpoint,
      Keyword.merge(endpoint,
        url: [path: if(base == "", do: "/", else: base)],
        secret_key_base: System.get_env("SECRET_KEY_BASE") || random(64)
      )
    )

    # Ecto.Migrator of phx.new runs the migrations in a release only.
    System.get_env("RELEASE_NAME") || System.put_env("RELEASE_NAME", "studio")

    children = [
      {Phoenix.PubSub, name: Studio.PubSub},
      {Task.Supervisor, name: Studio.Tasks},
      StudioWeb.Endpoint,
      {Studio.Project, root: root, base: base},
      {Bandit, plug: Studio.Front, port: port, ip: {127, 0, 0, 1}, startup_log: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Studio.Supervisor)
  end

  # STUDIO_BASE_PATH, or the path of a tenant of Workers: "" or "/a/b".
  defp base_path do
    path = System.get_env("STUDIO_BASE_PATH") || System.get_env("BEAM_TENANT_PATH") || ""
    path = String.trim_trailing(path, "/")

    if path == "" or Regex.match?(~r{^(/[A-Za-z0-9._~-]+)+$}, path),
      do: path,
      else: raise("STUDIO_BASE_PATH is not a path: #{inspect(path)}")
  end

  defp random(n),
    do: n |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false) |> binary_part(0, n)
end
