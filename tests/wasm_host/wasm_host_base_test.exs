defmodule WasmHostBaseTest do
  @moduledoc """
  The tests of `:wasm_host_base`: the base path of a web app in the url of
  each Phoenix endpoint.

  The module is not async: the tests load an application and change the
  environment of the OS process.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  describe "url_path/2" do
    for path <- ["/", "/a", "/a/b", "/REPO/app"] do
      test "the path #{path}" do
        assert {:ok, [path: unquote(path)]} == :wasm_host_base.url_path([], ~c"#{unquote(path)}")
      end
    end

    test "the other keys of url stay" do
      url = [host: "localhost", port: 443, scheme: "https", path: "/old"]

      assert {:ok, [host: "localhost", port: 443, scheme: "https", path: "/a"]} ==
               :wasm_host_base.url_path(url, ~c"/a")
    end

    test "an endpoint with no url" do
      assert {:ok, [path: "/a"]} == :wasm_host_base.url_path(nil, ~c"/a")
    end

    for path <- ["", "a", "a/b", "/a/", "//a", "/a//b", "/a?b=1", "/a#b", "http://x/a", "/a b"] do
      test "not a path: #{inspect(path)}" do
        assert {:error, {:bad_base_path, ~c"#{unquote(path)}"}} ==
                 :wasm_host_base.url_path([], ~c"#{unquote(path)}")
      end
    end

    property "a path of segments" do
      check all(segments <- list_of(string(:alphanumeric, min_length: 1), min_length: 1)) do
        path = "/" <> Enum.join(segments, "/")
        assert {:ok, [path: ^path]} = :wasm_host_base.url_path([], String.to_charlist(path))
      end
    end
  end

  describe "set/0" do
    setup do
      # An endpoint (the behaviour Phoenix.Endpoint) and a repo, in the
      # environment of a loaded application.
      endpoint = :"Elixir.WasmHostBaseTest.Endpoint"
      repo = :"Elixir.WasmHostBaseTest.Repo"
      load(endpoint, [{:attribute, 1, :behaviour, :"Elixir.Phoenix.Endpoint"}])
      load(repo, [])

      env = [
        {endpoint, [url: [host: "localhost"], server: true]},
        {repo, [database: "/tmp/app.db"]},
        {:other, [url: [host: "x"]]}
      ]

      :ok = :application.load({:application, :wasm_host_base_test, [env: env]})
      old = System.get_env("BEAM_BASE_PATH")

      # set/1 writes a persistent value, which stays after an unload.
      on_exit(fn ->
        :application.unset_env(:wasm_host_base_test, endpoint, persistent: true)
        :application.unload(:wasm_host_base_test)

        if old,
          do: System.put_env("BEAM_BASE_PATH", old),
          else: System.delete_env("BEAM_BASE_PATH")
      end)

      %{endpoint: endpoint, repo: repo}
    end

    test "BEAM_BASE_PATH in the url of each endpoint", %{endpoint: endpoint, repo: repo} do
      System.put_env("BEAM_BASE_PATH", "/repo/app")
      assert :ok == :wasm_host_base.set()

      assert [url: [host: "localhost", path: "/repo/app"], server: true] ==
               Application.get_env(:wasm_host_base_test, endpoint)

      assert [database: "/tmp/app.db"] == Application.get_env(:wasm_host_base_test, repo)
      assert [url: [host: "x"]] == Application.get_env(:wasm_host_base_test, :other)
    end

    test "no BEAM_BASE_PATH: no change", %{endpoint: endpoint} do
      System.delete_env("BEAM_BASE_PATH")
      assert :ok == :wasm_host_base.set()

      assert [url: [host: "localhost"], server: true] ==
               Application.get_env(:wasm_host_base_test, endpoint)
    end

    test "a value that is not a path stops the boot" do
      assert {:bad_base_path, ~c"repo"} == error_of(fn -> :wasm_host_base.set(~c"repo") end)
    end
  end

  test "endpoint/1" do
    refute :wasm_host_base.endpoint(:lists)
    refute :wasm_host_base.endpoint(:"Elixir.WasmHostBaseTest.NotLoaded")
    refute :wasm_host_base.endpoint("Elixir.A")
  end

  defp load(mod, attributes) do
    {:ok, ^mod, bin} = :compile.forms([{:attribute, 1, :module, mod} | attributes], [:binary])
    {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", bin)
  end

  defp error_of(fun) do
    fun.()
    flunk("no error")
  catch
    :error, reason -> reason
  end
end
