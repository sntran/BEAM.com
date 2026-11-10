defmodule BeamComMixTest do
  @moduledoc """
  The tests of `:beam_com_mix`: when a Mix project needs Mix itself, and
  the release that a child beam.com makes with Mix.

  The module is not async: the tests read mix.exs with Mix, and they
  change the environment of Mix (see BeamComElixirTest).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    env = Mix.env()
    project = Mix.Project.get()
    file = Mix.Project.project_file()

    on_exit(fn ->
      Mix.env(env)
      if project && Mix.Project.get() != project, do: Mix.Project.push(project, file)
    end)

    %{dir: String.to_charlist(dir)}
  end

  describe "reasons" do
    test "a project of Hex deps and no config/runtime.exs needs no Mix", %{dir: dir} do
      config = [app: :a, deps: [{:jason, "~> 1.4"}, {:credo, git: "x", only: :dev}]]
      assert [] == :beam_com_mix.reasons(dir, config)
    end

    test "config/runtime.exs, deps that are not Hex packages, compilers, assets.deploy",
         %{dir: dir} do
      write(:filename.join(dir, ~c"config"), ~c"runtime.exs", "import Config\n")

      config = [
        app: :a,
        compilers: [:phoenix_live_view],
        aliases: ["assets.deploy": ["tailwind a --minify"], setup: ["deps.get"]],
        deps: [
          {:phoenix, "~> 1.8"},
          {:heroicons, github: "tailwindlabs/heroicons", app: false, compile: false},
          {:local, path: "../local"},
          {:tool, git: "https://example.com/tool.git", only: [:dev, :prod]},
          {:dev_only, git: "https://example.com/dev.git", only: :dev}
        ]
      ]

      assert [:runtime_exs, {:deps, [:heroicons, :local, :tool]}, :compilers, :"assets.deploy"] ==
               :beam_com_mix.reasons(dir, config)
    end

    test "reasons/1 reads mix.exs", %{dir: dir} do
      write(
        dir,
        ~c"mix.exs",
        "defmodule R.MixProject do\n  use Mix.Project\n" <>
          "  def project, do: [app: :r, version: \"0.1.0\", deps: [{:d, git: \"x\"}]]\nend\n"
      )

      assert [{:deps, [:d]}] == :beam_com_mix.reasons(dir)
    end
  end

  test "hex_deps and has_alias" do
    assert :beam_com_mix.hex_deps(deps: [{:jason, "~> 1.4"}])
    assert :beam_com_mix.hex_deps(deps: [{:jason, ">= 0.0.0", hex: :jason}])
    refute :beam_com_mix.hex_deps(deps: [{:a, git: "x"}, {:b, "~> 1.0", only: :test}])
    refute :beam_com_mix.hex_deps([])
    assert :beam_com_mix.has_alias([aliases: ["assets.deploy": []]], :"assets.deploy")
    refute :beam_com_mix.has_alias([aliases: [setup: []]], :"assets.deploy")
    refute :beam_com_mix.has_alias([], :"assets.deploy")
  end

  test "asset_tools: tailwind and esbuild of mix.exs with no target and no path" do
    deps = [:phoenix, :tailwind, :esbuild]

    version = fn
      :esbuild, :version -> "0.25.4"
      _app, _key -> :undefined
    end

    assert [:tailwind, :esbuild] == :beam_com_mix.asset_tools(version, deps)
    assert [] == :beam_com_mix.asset_tools(version, [:phoenix])
    assert [:tailwind] == :beam_com_mix.asset_tools(fn _app, _key -> :undefined end, deps)

    assert [:esbuild] ==
             :beam_com_mix.asset_tools(
               fn
                 :tailwind, :target -> "windows-x64.exe"
                 app, key -> version.(app, key)
               end,
               deps
             )

    assert [] ==
             :beam_com_mix.asset_tools(
               fn
                 _app, :path -> "/p"
                 app, key -> version.(app, key)
               end,
               deps
             )
  end

  describe "esbuild_exe" do
    # A package of npm as the registry gives it: the metadata of the
    # version, with the integrity and a signature over "ID:INTEGRITY",
    # and the tarball. The key is a new key of the test.
    setup %{dir: dir} do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _, _, params, point, _} = key
      tgz = npm_tarball(dir, [{~c"package/esbuild.exe", "MZ exe"}])

      %{
        key: key,
        tgz: tgz,
        limits: %{keys: %{"SHA256:test" => {{:ECPoint, point}, params}}, unpacked: 1_000_000},
        out: Path.join(dir, "_build") |> String.to_charlist()
      }
    end

    test "esbuild.exe of a signed package, and the file again", c do
      http = npm_http(npm_meta(c, "@esbuild/win32-x64", "0.25.4"), c.tgz)
      path = :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, http, c.limits)
      assert path == Path.join(c.out, "esbuild-win32-x64-0.25.4.exe") |> String.to_charlist()
      assert "MZ exe" == File.read!(path)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o755
      assert_received {:get, ~c"https://registry.npmjs.org/@esbuild/win32-x64/0.25.4", 1_048_576}

      assert_received {:get,
                       ~c"https://registry.npmjs.org/@esbuild/win32-x64/-/win32-x64-0.25.4.tgz",
                       67_108_864}

      assert path == :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, fn _, _, _, _, _ -> flunk() end)
      refute File.exists?(path ++ ~c".new")
    end

    test "esbuild before 0.16.0: the package esbuild-windows-64", c do
      http = npm_http(npm_meta(c, "esbuild-windows-64", "0.15.18"), c.tgz)
      path = :beam_com_mix.esbuild_exe(~c"0.15.18", c.out, http, c.limits)
      assert "MZ exe" == File.read!(path)
      assert_received {:get, ~c"https://registry.npmjs.org/esbuild-windows-64/0.15.18", _}
    end

    test "a signature that is not valid, or of no known key", c do
      meta = npm_meta(c, "@esbuild/win32-x64", "0.25.4")
      [sig] = meta["dist"]["signatures"]
      other = Base.encode64(:public_key.sign("another text", :sha256, c.key))

      for {sigs, text} <- [
            {[%{sig | "sig" => other}], ~c"~ts: the signature of npm is not valid"},
            {[%{sig | "sig" => "not base64!"}], ~c"~ts: the signature of npm is not valid"},
            {[%{sig | "keyid" => "SHA256:other"}], ~c"~ts: no signature of a known key of npm"},
            {[], ~c"~ts: no signature of a known key of npm"}
          ] do
        meta = put_in(meta, ["dist", "signatures"], sigs)

        assert {:error, ^text, [_]} =
                 catch_throw(
                   :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, npm_http(meta, c.tgz), c.limits)
                 )
      end

      # The real metadata of @esbuild/win32-x64 0.25.4 on npm, with the
      # real keys of npm.
      id = "@esbuild/win32-x64@0.25.4"

      integrity =
        "sha512-nOT2vZNw6hJ+z43oP1SPea/G/6AbN6X+bGNhNuq8NtRHy4wsMhw765IKLNmnjek7GvjWBYQ8Q5VBoYTFg9y1UQ=="

      real = [
        %{
          "keyid" => "SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U",
          "sig" =>
            "MEUCIBu9dqofAKq4xtr/lFRugJQ+3P+RCP62/nhAjhpVaGLMAiEAzGnN+hQLvISnIANHqE37Mzwb1pkgu0iibSm4IkFJPyw="
        }
      ]

      keys = :beam_com_mix.npm_keys()
      assert 2 == map_size(keys)
      assert :ok == :beam_com_mix.verify_npm(~c"u", id <> ":" <> integrity, real, keys)

      assert {:error, ~c"~ts: the signature of npm is not valid", _} =
               catch_throw(:beam_com_mix.verify_npm(~c"u", id <> ":" <> "x", real, keys))
    end

    test "metadata of another package, or with no integrity", c do
      cases = [
        {npm_meta(c, "@esbuild/win32-x64", "0.25.3"), ~c"~ts: the metadata is for ~ts"},
        {%{"_id" => "x"},
         ~c"~ts: the metadata has no _id, integrity, signatures or https tarball"},
        {put_in(
           npm_meta(c, "@esbuild/win32-x64", "0.25.4"),
           ["dist", "tarball"],
           "http://x/t.tgz"
         ), ~c"~ts: the metadata has no _id, integrity, signatures or https tarball"},
        {npm_meta(c, "@esbuild/win32-x64", "0.25.4", "sha1-AAAA"),
         ~c"~ts: the integrity is not sha512: ~ts"},
        {npm_meta(c, "@esbuild/win32-x64", "0.25.4", "sha512-!"), ~c"~ts: a bad integrity: ~ts"}
      ]

      for {meta, text} <- cases do
        assert {:error, ^text, _} =
                 catch_throw(
                   :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, npm_http(meta, c.tgz), c.limits)
                 )
      end

      assert {:error, ~c"~ts: the metadata is not JSON", _} =
               catch_throw(
                 :beam_com_mix.esbuild_exe(
                   ~c"0.25.4",
                   c.out,
                   fn _, _, _, _, _ -> "<html>" end,
                   c.limits
                 )
               )
    end

    test "a tarball that is not the signed one, not gzip, too large, or with no esbuild.exe",
         %{dir: dir} = c do
      meta = npm_meta(c, "@esbuild/win32-x64", "0.25.4")

      assert {:error, ~c"~ts: the SHA-512 of the tarball is not the signed integrity", _} =
               catch_throw(
                 :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, npm_http(meta, "other"), c.limits)
               )

      tgzs = [
        {"not gzip", ~c"~ts: not a gzip file"},
        {npm_tarball(dir, [{~c"package/esbuild.exe", :binary.copy("x", 1_000_001)}]),
         ~c"~ts: the tarball has more than ~b bytes without compression"},
        {npm_tarball(dir, [{~c"package/README.md", "no exe"}]), ~c"~ts: no package/esbuild.exe"}
      ]

      for {tgz, text} <- tgzs do
        meta = npm_meta(c, "@esbuild/win32-x64", "0.25.4", npm_integrity(tgz))

        assert {:error, ^text, _} =
                 catch_throw(
                   :beam_com_mix.esbuild_exe(~c"0.25.4", c.out, npm_http(meta, tgz), c.limits)
                 )
      end

      refute File.exists?(c.out)
    end

    test "a failed write", %{dir: dir} = c do
      out = write(dir, ~c"file", "")
      http = npm_http(npm_meta(c, "@esbuild/win32-x64", "0.25.4"), c.tgz)

      dir = :filename.join(out, ~c"_build")

      assert {:error, ~c"~ts: ~ts", [^dir, ~c"not a directory"]} =
               catch_throw(
                 :beam_com_mix.esbuild_exe(
                   ~c"0.25.4",
                   dir,
                   http,
                   c.limits
                 )
               )
    end
  end

  test "windows_assets: only for the step assets.deploy and the deps of the environment" do
    no_http = [deps: [{:esbuild, "~> 0.10"}, {:tailwind, "~> 0.3", only: :test}]]
    on_exit(fn -> Application.delete_env(:tailwind, :target, persistent: true) end)
    assert :ok == :beam_com_mix.windows_assets({:unix, :windows}, no_http)
    assert :undefined == :application.get_env(:tailwind, :target)

    config = [
      aliases: ["assets.deploy": ["tailwind a"]],
      deps: [{:esbuild, "~> 0.10", only: :dev}, {:tailwind, "~> 0.3", only: :test}]
    ]

    assert :ok == :beam_com_mix.windows_assets({:unix, :linux}, config)
    assert :undefined == :application.get_env(:tailwind, :target)

    assert capture_io(fn -> :ok = :beam_com_mix.windows_assets({:unix, :windows}, config) end) ==
             "beam.com: tailwind for Windows (target windows-x64.exe)\n"

    assert {:ok, "windows-x64.exe"} == :application.get_env(:tailwind, :target)
  end

  test "releases: include_erts false and a directory in Out, for each release" do
    assert [app: [include_erts: false, path: "/out/app"]] ==
             :beam_com_mix.releases(:app, [], ~c"/out")

    assert [
             one: [applications: [x: :permanent], include_erts: false, path: "/out/one"],
             two: [path: "/out/two", include_erts: false]
           ] ==
             :beam_com_mix.releases(
               :app,
               [one: [applications: [x: :permanent], include_erts: true], two: [path: "/p"]],
               ~c"/out"
             )
  end

  test "child_env: MIX_ENV of the user, else prod" do
    base = [{~c"BEAM_COM_MIX_DIR", ~c"/d"}, {~c"BEAM_COM_MIX_OUT", ~c"/o"}]
    assert base ++ [{~c"MIX_ENV", ~c"prod"}] == :beam_com_mix.child_env(~c"/d", ~c"/o", false)
    assert base ++ [{~c"MIX_ENV", ~c"prod"}] == :beam_com_mix.child_env(~c"/d", ~c"/o", ~c"")
    assert base == :beam_com_mix.child_env(~c"/d", ~c"/o", ~c"staging")
  end

  test "no_input: the output goes to the leader, and each read gets eof" do
    {:ok, out} = StringIO.open("an answer that nobody reads\n")
    leader = :beam_com_mix.no_input(out)

    IO.write(leader, "a line\n")
    assert :eof == IO.gets(leader, "Shall I install Hex? [Yn] ")
    assert :eof == IO.read(leader, 3)
    assert :eof == :io.get_password(leader)
    assert :eof == :io.request(leader, {:get_until, :unicode, :prompt, :erl_scan, :tokens, [1]})
    assert :ok == :io.requests(leader, [{:put_chars, :unicode, "x"}, {:put_chars, :unicode, "y"}])
    assert :eof == :io.requests(leader, [{:get_line, :unicode, "?"}, {:put_chars, :unicode, "z"}])

    assert {"an answer that nobody reads\n", "a line\nShall I install Hex? [Yn] promptxy?"} ==
             StringIO.contents(out)
  end

  describe "the output and the errors of the child" do
    test "relay: a character in two parts, and bytes that are not UTF-8" do
      port = make_ref()
      send(self(), {port, {:data, <<0xE2, 0x94>>}})
      send(self(), {port, {:data, <<0x82, "caf", 0xE9, "\n", 0xE2>>}})
      send(self(), {port, {:exit_status, 3}})

      assert capture_io(fn -> send(self(), {:status, :beam_com_mix.relay(port)}) end) ==
               "\u2502caf\uFFFD\n\uFFFD"

      assert_received {:status, 3}
    end

    test "relay: the output of a port program, in parts of any size", %{dir: dir} do
      big = String.duplicate("\u2502", 30_000) <> "\n"
      file = write(dir, ~c"big.txt", big <> <<"caf", 0xE9, "\n">>)

      port =
        Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status, args: [file]])

      assert capture_io(fn -> send(self(), {:status, :beam_com_mix.relay(port)}) end) ==
               big <> "caf\uFFFD\n"

      assert_received {:status, 0}
    end

    test "status: 0, or 1 with the message of the error" do
      assert 0 == :beam_com_mix.status(fn -> :ok end)

      assert capture_io(:stderr, fn ->
               assert 1 == :beam_com_mix.status(fn -> throw({:error, ~c"no ~ts", ["x"]}) end)
             end) == "beam.com: no x\n"

      assert capture_io(:stderr, fn ->
               assert 1 == :beam_com_mix.status(fn -> Mix.raise("a Mix error") end)
             end) == "beam.com: a Mix error\n"

      assert capture_io(:stderr, fn ->
               assert 1 == :beam_com_mix.status(fn -> raise ArgumentError, "bad" end)
             end) =~ "beam.com: ** (ArgumentError) bad"
    end

    test "watch_input: the end of the input stops the child" do
      {:ok, input} = StringIO.open("a line\nanother line\n")
      parent = self()

      :ok =
        :beam_com_mix.watch_input(input, fn ->
          send(parent, :halt)
          :ok
        end)

      assert_received :halt
      assert {"", ""} == StringIO.contents(input)
    end

    test "release: an error removes the directory of the release", %{dir: dir} do
      # A program in place of beam.com: it prints bytes that are not
      # UTF-8, and it makes no release.
      exe = write(dir, ~c"exe.sh", "#!/bin/sh\nprintf 'caf\\351\\n'\nexit 0\n")
      :ok = :file.change_mode(exe, 0o755)
      out = :filename.join(dir, ~c"out")
      :ok = :file.make_dir(out)

      {{:error, format, [^dir, ^out]}, output} =
        with_io(fn -> catch_throw(:beam_com_mix.release(dir, %{out: out, exe: exe})) end)

      assert format == ~c"~ts: Mix made no release in ~ts"
      assert output == "caf\uFFFD\n"
      refute File.exists?(out)

      exe = write(dir, ~c"exe.sh", "#!/bin/sh\nexit 7\n")
      :ok = :file.make_dir(out)

      assert {:error, _, [^dir, 7]} =
               catch_throw(:beam_com_mix.release(dir, %{out: out, exe: exe}))

      refute File.exists?(out)

      :ok = :file.make_dir(out)

      assert :enoent ==
               catch_error(
                 :beam_com_mix.release(dir, %{out: out, exe: :filename.join(dir, ~c"none")})
               )

      refute File.exists?(out)
    end
  end

  describe "the choice of the builder" do
    test "Mix makes the release only for a Mix project that needs it", %{dir: dir} do
      assert :none == :beam_com_build.mix_release(dir, %{})

      assert {:error, ~c"~ts: --tool mix-release needs a Mix project (mix.exs)", [^dir]} =
               catch_throw(:beam_com_build.mix_release(dir, %{tool: :mix_release}))

      write(
        dir,
        ~c"mix.exs",
        "defmodule C.MixProject do\n  use Mix.Project\n" <>
          "  def project, do: [app: :c, version: \"0.1.0\", deps: []]\nend\n"
      )

      assert :none == :beam_com_build.mix_release(dir, %{})
      write(:filename.join(dir, ~c"config"), ~c"runtime.exs", "import Config\n")
      assert :none == :beam_com_build.mix_release(dir, %{tool: :mix})
      assert :none == :beam_com_build.mix_release(dir, %{tool: :rebar})
      # A directory with rebar.config and mix.exs is a rebar3 project.
      write(dir, ~c"rebar.config", "{deps, []}.\n")
      assert :none == :beam_com_build.mix_release(dir, %{})
    end

    test "why: the reasons in the line of the build" do
      assert "config/runtime.exs, deps that are not Hex packages: a b, " <>
               "the compilers of mix.exs, the alias assets.deploy, --tool mix-release" ==
               IO.iodata_to_binary(
                 :beam_com_build.why([
                   :runtime_exs,
                   {:deps, [:a, :b]},
                   :compilers,
                   :"assets.deploy",
                   :tool
                 ])
               )
    end
  end

  # The child is this beam.com (the init argument beam_com_exe of
  # beam_com.c), with the code of this commit only in the beam.com of
  # the build (scripts/steps.sh unit).
  describe "release" do
    @describetag timeout: 600_000

    setup do
      case :init.get_argument(:beam_com_exe) do
        {:ok, [[exe]]} -> %{exe: exe}
        :error -> :ok
      end
    end

    test "Mix makes a release with include_erts false and config/runtime.exs",
         %{dir: dir} = context do
      if exe = context[:exe] do
        project = copy_project(dir)
        out = :filename.join(dir, ~c"out")
        :ok = :file.make_dir(out)

        # A relative path, as in "beam.com . -o FILE": the child starts
        # in the project.
        relative = project |> Path.relative_to_cwd() |> String.to_charlist()
        assert relative != project

        {rel, output} =
          own_mix_paths(fn ->
            with_io(fn -> :beam_com_mix.release(relative, %{out: out, exe: exe}) end)
          end)

        assert rel == :filename.join(out, ~c"runtime_check")
        assert File.exists?(Path.join([rel, "releases", "0.1.0", "runtime.exs"]))
        assert File.exists?(Path.join([rel, "lib", "runtime_check-0.1.0", "ebin"]))
        assert [] == Path.wildcard(Path.join(rel, "erts-*"))
        # Mix writes _build in the project, as "mix release" does.
        assert File.dir?(Path.join([project, "_build", "prod"]))
        refute output =~ "Hex"
      end
    end

    test "an error of Mix: the exit status of the child", %{dir: dir} = context do
      if exe = context[:exe] do
        project = :filename.join(dir, ~c"bad")

        write(
          project,
          ~c"mix.exs",
          "defmodule Bad.MixProject do\n  use Mix.Project\n" <>
            "  def project, do: [app: :bad, version: \"0.1.0\", deps: [{:none, path: \"none\"}]]\nend\n"
        )

        {{:error, format, [^project, status]}, output} =
          own_mix_paths(fn ->
            with_io(fn -> catch_throw(:beam_com_mix.release(project, %{out: dir, exe: exe})) end)
          end)

        assert format == ~c"~ts: Mix did not make a release (exit status ~p)"
        assert status != 0
        assert output =~ "beam.com: "
      end
    end
  end

  # The child uses the environment of the builder. The tests run with
  # MIX_BUILD_ROOT, MIX_DEPS_PATH and MIX_ENV of the test build
  # (scripts/steps.sh unit): without them, Mix uses _build and deps of
  # the project, and the environment prod.
  defp own_mix_paths(fun) do
    saved = for v <- ["MIX_BUILD_ROOT", "MIX_DEPS_PATH", "MIX_ENV"], do: {v, System.get_env(v)}

    try do
      Enum.each(saved, fn {v, _} -> System.delete_env(v) end)
      fun.()
    after
      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, value} -> System.put_env(v, value)
      end)
    end
  end

  defp copy_project(dir) do
    project = :filename.join(dir, ~c"runtime_check")
    File.cp_r!(Path.expand("../programs/runtime_check", __DIR__), to_string(project))
    project
  end

  defp npm_tarball(dir, files) do
    tgz = :filename.join(dir, ~c"e.tgz")
    :ok = :erl_tar.create(tgz, files, [:compressed])
    File.read!(tgz)
  end

  defp npm_integrity(tgz), do: "sha512-" <> Base.encode64(:crypto.hash(:sha512, tgz))

  defp npm_meta(c, name, version, integrity \\ nil) do
    integrity = integrity || npm_integrity(c.tgz)
    id = "#{name}@#{version}"
    sig = Base.encode64(:public_key.sign(id <> ":" <> integrity, :sha256, c.key))
    base = name |> String.split("/") |> List.last()

    %{
      "_id" => id,
      "dist" => %{
        "integrity" => integrity,
        "signatures" => [%{"keyid" => "SHA256:test", "sig" => sig}],
        "tarball" => "https://registry.npmjs.org/#{name}/-/#{base}-#{version}.tgz"
      }
    }
  end

  # The function of :beam_com_hex.http/5: the metadata, then the tarball.
  defp npm_http(meta, tgz) do
    parent = self()

    fn :get, url, [], :none, max ->
      send(parent, {:get, url, max})
      if List.to_string(url) =~ ~r/\.tgz$/, do: tgz, else: JSON.encode!(meta)
    end
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    file = :filename.join(dir, name)
    :ok = :file.write_file(file, content)
    file
  end
end
