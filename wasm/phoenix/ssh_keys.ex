defmodule HelloWeb.SshKeys do
  @moduledoc """
  The host key of the SSH test server (`GET /ssh`): an Ed25519 key, made
  at the first use and kept in a persistent term (no files). Only
  passwords are accepted for users.
  """
  @behaviour :ssh_server_key_api

  @impl true
  def host_key(:"ssh-ed25519", _opts) do
    key =
      case :persistent_term.get(__MODULE__, nil) do
        nil ->
          k = :public_key.generate_key({:namedCurve, :ed25519})
          :persistent_term.put(__MODULE__, k)
          k

        k ->
          k
      end

    {:ok, key}
  end

  def host_key(_alg, _opts), do: {:error, :no_key}

  @impl true
  def is_auth_key(_key, _user, _opts), do: false
end
