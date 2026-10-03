defmodule BeamComWasmTest do
  @moduledoc """
  The tests of `:beam_com_wasm`, the build for `--target wasm32`.

  The module is not async: the tests of `runtime_dir/1` change the
  environment of the OS process, and other tests load modules.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @ebin ~c"$ROOT/lib/wasm_host-0.1.0/ebin"

  describe "vm_args_test_" do
    test "a comment and -noshell" do
      assert [] == :beam_com_wasm.vm_args("## a comment\n-noshell\n")
    end

    test "no emulator flags, no node name, no -env" do
      assert [~c"-kernel", ~c"shell_history", ~c"enabled", ~c"-s", ~c"m"] ==
               :beam_com_wasm.vm_args(
                 "+S 4\n+A 8\n-sname app # the name\n-setcookie c\n" <>
                   "-env A 1\n+sbwt none\n-kernel shell_history enabled\n" <> "-s m\n"
               )
    end

    test "a flag of the emulator without a value" do
      assert [~c"-mode", ~c"embedded"] == :beam_com_wasm.vm_args("+Bi\n-mode embedded\n")
    end
  end

  describe "with_host_test_" do
    setup %{tmp_dir: dir} do
      root = root(dir)
      files = :beam_com_wasm.with_host([{~c"releases/1/start.boot", boot()}], root)
      %{root: root, files: files, cmds: commands(files)}
    end

    test "the files of wasm_host", %{files: files} do
      assert List.keymember?(files, ~c"lib/wasm_host-0.1.0/ebin/wasm_tcp.beam", 0)
    end

    # A path command replaces the one before it.
    test "the paths with stdlib get the ebin of wasm_host: the first path", %{cmds: cmds} do
      assert {:path, [~c"$ROOT/lib/kernel-1/ebin", ~c"$ROOT/lib/stdlib-2/ebin", @ebin]} in cmds
    end

    test "the paths with stdlib get the ebin of wasm_host: the path of stdlib", %{cmds: cmds} do
      assert {:path, [~c"$ROOT/lib/stdlib-2/ebin", @ebin]} in cmds
    end

    test "the paths with stdlib get the ebin of wasm_host: the path of kernel", %{cmds: cmds} do
      assert {:path, [~c"$ROOT/lib/kernel-1/ebin"]} in cmds
    end

    test "wasm_host starts after stdlib, before the program", %{cmds: cmds} do
      assert [:stdlib, :wasm_host, :app] ==
               for({:apply, {:application, :start_boot, [a, _]}} <- cmds, a != :kernel, do: a)
    end

    test "with no config provider, the base path is set after wasm_host starts", %{cmds: cmds} do
      start = {:apply, {:application, :start_boot, [:wasm_host, :permanent]}}

      assert [^start, {:apply, {:wasm_host_base, :set, []}} | _] =
               Enum.drop_while(cmds, &(&1 != start))
    end

    # runtime.exs of a Mix release must not replace the base path.
    test "with a config provider, the base path is set after it", %{root: root} do
      provider = {:apply, {:"Elixir.Config.Provider", :boot, []}}
      base = {:apply, {:wasm_host_base, :set, []}}

      cmds =
        commands(:beam_com_wasm.with_host([{~c"releases/1/start.boot", boot([provider])}], root))

      assert [^provider, ^base, {:apply, {:application, :start_boot, [:app, _]}}] =
               Enum.drop_while(cmds, &(&1 != provider))

      assert 1 == Enum.count(cmds, &(&1 == base))
    end

    test "and it is loaded first", %{cmds: cmds} do
      assert [{:apply, {:application, :load, [{:application, :wasm_host, _}]}}] =
               for({:apply, {:application, :load, _}} = c <- cmds, do: c)
    end

    test "a release with its own copy of a module of wasm_host", %{root: root} do
      assert {:error, ~c"~ts: the release has its own copy of a module of wasm_host; remove it",
              [~c"lib/app-1/ebin/wasm_tcp.beam"]} ==
               catch_throw(
                 :beam_com_wasm.with_host([{~c"lib/app-1/ebin/wasm_tcp.beam", ""}], root)
               )
    end
  end

  describe "with_boot_modules_test_" do
    setup do
      %{files: [{~c"releases/1/start.boot", boot()}, {~c"lib/a-1/ebin/a.beam", "x"}]}
    end

    test "no boot modules: no change", %{files: files} do
      assert files == :beam_com_wasm.with_boot_modules(files, [])
    end

    test "the batch after kernel starts", %{files: files} do
      cmds = commands(:beam_com_wasm.with_boot_modules(files, [:lists, :maps]))

      assert [
               _,
               {:apply, {:application, :start_boot, [:kernel, _]}},
               {:apply, {:code, :ensure_modules_loaded, [[:lists, :maps]]}},
               {:apply, {:application, :start_boot, [:stdlib, _]}} | _
             ] = :lists.nthtail(7, cmds)
    end
  end

  describe "meta_test_" do
    test "a release of beam.com: its sys.config, and the flags of vm.args" do
      files = [
        {~c"releases/1/vm.args", "-sname a\n-s m\n"},
        {~c"releases/1/sys.config", "[]."}
      ]

      assert %{
               name: "app",
               vsn: "1",
               env: %{},
               sql: false,
               args: [
                 "-mode",
                 "interactive",
                 "-config",
                 "/app/releases/1/sys",
                 "-boot",
                 "/app/releases/1/start",
                 "-boot_var",
                 "RELEASE_LIB",
                 "/app/lib",
                 "-s",
                 "m"
               ]
             } ==
               :beam_com_wasm.meta(%{name: ~c"app", vsn: ~c"1", kind: :beam_com, files: files})
    end

    # The runtime.exs of Ecto SQLite needs DATABASE_PATH; a variable of the
    # host replaces it (worker.js).
    test "Ecto SQLite: DATABASE_PATH in the memory of the VM" do
      assert %{env: %{DATABASE_PATH: "/tmp/app.db"}} =
               :beam_com_wasm.meta(%{
                 name: ~c"app",
                 vsn: ~c"1",
                 kind: :beam_com,
                 files: [],
                 apps: [:exqlite]
               })

      refute Map.has_key?(
               :beam_com_wasm.meta(%{name: ~c"app", vsn: ~c"1", kind: :beam_com, files: []}).env,
               :DATABASE_PATH
             )
    end

    test "a mix release: the runtime configuration in tmp/, and PHX_SERVER for Phoenix" do
      assert %{
               args: ["-mode", "interactive", "-config", "/app/tmp/run.runtime" | _],
               env: %{PHX_SERVER: "true"}
             } =
               :beam_com_wasm.meta(%{
                 name: ~c"app",
                 vsn: ~c"1",
                 kind: :mix,
                 files: [],
                 apps: [:phoenix]
               })
    end

    test "Ecto SQLite: sql" do
      assert %{sql: true} =
               :beam_com_wasm.meta(%{
                 name: ~c"app",
                 vsn: ~c"1",
                 kind: :mix,
                 files: [],
                 apps: [:exqlite]
               })
    end

    test "--cacerts: public_key reads the file of the release" do
      assert %{
               args: [
                 "-mode",
                 "interactive",
                 "-public_key",
                 "cacerts_path",
                 "\"/app/etc/cacerts.pem\"" | _
               ]
             } =
               :beam_com_wasm.meta(%{
                 name: ~c"app",
                 vsn: ~c"1",
                 kind: :beam_com,
                 files: [],
                 cacerts: true
               })
    end
  end

  describe "with_cacerts_test_" do
    setup %{tmp_dir: dir} do
      %{cert: der} = :public_key.pkix_test_root_cert(~c"beam_com test root", [])
      cert = {:Certificate, der, :not_encrypted}
      pem = String.to_charlist(Path.join(dir, "roots.pem"))
      :ok = :file.write_file(pem, ["a comment\n", :public_key.pem_encode([cert, cert])])
      empty = String.to_charlist(Path.join(dir, "empty.pem"))
      :ok = :file.write_file(empty, "no certificate here\n")
      absent = String.to_charlist(Path.join(dir, "absent.pem"))
      %{cert: cert, pem: pem, empty: empty, absent: absent}
    end

    test "no --cacerts: no file (not the store of this computer)" do
      assert [{~c"a", ""}] == :beam_com_wasm.with_cacerts([{~c"a", ""}], %{})
    end

    test "--cacerts FILE: its certificates in etc/cacerts.pem", %{cert: cert, pem: pem} do
      assert [{~c"a", ""}, {~c"etc/cacerts.pem", :public_key.pem_encode([cert, cert])}] ==
               :beam_com_wasm.with_cacerts([{~c"a", ""}], %{cacerts: pem})
    end

    test "a file with no certificate", %{empty: empty} do
      assert {:error, ~c"--cacerts ~ts: no certificate", [empty]} ==
               catch_throw(:beam_com_wasm.with_cacerts([], %{cacerts: empty}))
    end

    test "a file that is not there", %{absent: absent} do
      assert {:error, ~c"--cacerts ~ts: ~ts", [^absent, _]} =
               catch_throw(:beam_com_wasm.with_cacerts([], %{cacerts: absent}))
    end
  end

  test "pack_test" do
    bin = IO.iodata_to_binary(:beam_com_wasm.pack([{~c"a", "xy"}, {~c"é", ["z"]}]))
    assert <<"BEAMFS1\n", 1::32, "a", 2::32, "xy", 2::32, "é", 1::32, "z">> == bin
  end

  describe "runtime_dir_test_" do
    setup %{tmp_dir: dir} do
      root = root(dir)
      old_cache = System.get_env("BEAM_COM_CACHE")
      old_runtime = System.get_env("BEAM_COM_WASM_RUNTIME")
      System.put_env("BEAM_COM_CACHE", Path.join(dir, "cache"))
      System.delete_env("BEAM_COM_WASM_RUNTIME")

      on_exit(fn ->
        restore_env("BEAM_COM_WASM_RUNTIME", old_runtime)
        restore_env("BEAM_COM_CACHE", old_cache)
      end)

      %{root: root, runtime: :filename.join(root, ~c"runtime")}
    end

    test "no runtime", %{root: root} do
      assert {:error,
              ~c"the WebAssembly runtime (beam.wasm and beam.mjs) is not in ~ts: " ++
                ~c"set BEAM_COM_WASM_RUNTIME to its directory, or put it in ~ts", _} =
               catch_throw(:beam_com_wasm.runtime_dir(root))
    end

    test "BEAM_COM_WASM_RUNTIME", %{root: root, runtime: runtime} do
      :ok = :filelib.ensure_path(runtime)

      for f <- [~c"beam.wasm", ~c"beam.mjs"],
          do: :ok = :file.write_file(:filename.join(runtime, f), "")

      System.put_env("BEAM_COM_WASM_RUNTIME", List.to_string(runtime))
      assert runtime == :beam_com_wasm.runtime_dir(root)
      System.delete_env("BEAM_COM_WASM_RUNTIME")
    end

    test "in the zip", %{root: root} do
      priv = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"runtime"])
      :ok = :filelib.ensure_path(priv)

      for f <- [~c"beam.wasm", ~c"beam.mjs"],
          do: :ok = :file.write_file(:filename.join(priv, f), "")

      assert priv == :beam_com_wasm.runtime_dir(root)
    end
  end

  describe "snapshot_key_test_" do
    setup do
      files = [{~c"lib/a-1/ebin/a.beam", "x"}]

      worker = [
        {~c"worker.js", "w"},
        {~c"beam.mjs", "m"},
        {~c"beam.wasm", "b"},
        {~c"worker.capnp", "a random key"}
      ]

      %{files: files, worker: worker, key: :beam_com_wasm.snapshot_key(files, worker)}
    end

    test "the key has 64 bytes", %{key: key} do
      assert 64 == byte_size(key)
    end

    test "the same runtime, Worker and release: the same key", %{files: f, worker: w, key: key} do
      other = :lists.keyreplace(~c"worker.capnp", 1, w, {~c"worker.capnp", "other"})
      assert key == :beam_com_wasm.snapshot_key(f, other)
    end

    test "another release: another key", %{worker: w, key: key} do
      assert key != :beam_com_wasm.snapshot_key([{~c"lib/a-1/ebin/a.beam", "y"}], w)
    end

    test "another runtime: another key", %{files: f, worker: w, key: key} do
      other = :lists.keyreplace(~c"beam.wasm", 1, w, {~c"beam.wasm", "c"})
      assert key != :beam_com_wasm.snapshot_key(f, other)
    end
  end

  # The files of the output directory: the global scope variant only
  # without Ecto SQLite, the Durable Object with its own name, and the
  # Worker with the release with no public URL.
  test "worker_files_test", %{tmp_dir: dir} do
    root = root(dir)
    priv = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"worker"])
    runtime = :filename.join(root, ~c"runtime")
    for d <- [priv, runtime], do: :ok = :filelib.ensure_path(d)

    for f <- [
          ~c"app-com.js",
          ~c"durable.js",
          ~c"global.js",
          ~c"durable-global.js",
          ~c"tcp-proxy.mjs",
          ~c"app.js",
          ~c"cloudflare/index.js",
          ~c"cloudflare/release.js",
          ~c"cloudflare/snapshot.js"
        ] do
      :ok = :filelib.ensure_dir(:filename.join(priv, f))
      :ok = :file.write_file(:filename.join(priv, f), f)
    end

    # The imports of worker.js that each host gives (host_worker/2).
    worker_js = """
    import net from 'node:net';
    import createBeam from './beam.mjs';
    import wasm from './beam.wasm';
    const release = (await import('./release.bin')).default;
    const snapshot = await import('./snapshot.bin');
    """

    :ok = :file.write_file(:filename.join(priv, ~c"worker.js"), worker_js)

    for f <- [~c"beam.mjs", ~c"beam.wasm"],
        do: :ok = :file.write_file(:filename.join(runtime, f), f)

    # The other hosts of worker.js, with their subdirectories.
    hosts = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv"])

    for f <- [
          ~c"deno/deno.js",
          ~c"deno/deno.json",
          ~c"deno/deno/beam-wasm.js",
          ~c"browser/browser.js",
          ~c"browser/browser/none.js"
        ] do
      :ok = :filelib.ensure_dir(:filename.join(hosts, f))
      :ok = :file.write_file(:filename.join(hosts, f), f)
    end

    :ok = :filelib.ensure_path(:filename.join([root, ~c"licenses", ~c"otp"]))

    for f <- [[~c"NOTICE"], [~c"otp", ~c"MIT.txt"]],
        do: :ok = :file.write_file(:filename.join([root, ~c"licenses" | f]), "text")

    files = fn name, apps ->
      for {f, d} <- :beam_com_wasm.worker_files(%{name: name, apps: apps}, runtime, root),
          do: {f, IO.iodata_to_binary(d)}
    end

    has = fn fs, name, text -> :binary.match(:proplists.get_value(name, fs), text) != :nomatch end
    get = &:proplists.get_value/2

    plain = files.(~c"app", [])
    # The license texts of the zip, with the texts of OTP.
    assert "text" == get.(~c"licenses/NOTICE", plain)
    assert "text" == get.(~c"licenses/otp/MIT.txt", plain)
    # The files of Deno and of a web page, next to worker.js, and the
    # reader of a native app.com (BEAM_APP of Deno).
    assert "app-com.js" == get.(~c"app-com.js", plain)
    # The identity of the runtime, as a module (runtime_id_test_).
    id = :beam_com_wasm.runtime_id(plain)

    assert id ==
             :beam_com_wasm.runtime_id(
               [{~c"worker.js", worker_js}] ++
                 for(f <- ~w(app-com.js beam.mjs beam.wasm)c, do: {f, f})
             )

    assert get.(~c"runtime-id.js", plain) =~ "\nexport default '#{id}';\n"
    assert "deno/deno.js" == get.(~c"deno.js", plain)
    assert "deno/deno.json" == get.(~c"deno.json", plain)
    assert "deno/deno/beam-wasm.js" == get.(~c"deno/beam-wasm.js", plain)
    assert "browser/browser.js" == get.(~c"browser.js", plain)
    assert "browser/browser/none.js" == get.(~c"browser/none.js", plain)
    assert "global.js" == get.(~c"global.js", plain)

    # The hosts of a native app.com (app_hosts/1): copies of worker.js with
    # the imports of deno/ and of cloudflare/.
    deno = get.(~c"deno/worker.js", plain)
    assert deno =~ "from '../beam.mjs'"
    assert deno =~ "from './beam-wasm.js'"
    assert deno =~ "import('./release-bin.js')"
    assert deno =~ "import('./snapshot-bin.js')"
    assert deno =~ "from 'node:net'"
    cloudflare = get.(~c"cloudflare/worker.js", plain)
    assert cloudflare =~ "from '../beam.mjs'"
    assert cloudflare =~ "from '../beam.wasm'"
    assert cloudflare =~ "(await import('./release.js')).release()"
    assert cloudflare =~ "import('./snapshot.js')"
    assert "durable.js" == get.(~c"cloudflare/durable.js", plain)
    assert "cloudflare/index.js" == get.(~c"cloudflare/index.js", plain)
    assert "cloudflare/release.js" == get.(~c"cloudflare/release.js", plain)
    assert "cloudflare/snapshot.js" == get.(~c"cloudflare/snapshot.js", plain)
    assert has.(plain, ~c"wrangler.global.jsonc", "\"main\": \"global.js\"")
    assert has.(plain, ~c"wrangler.global.jsonc", "\"BEAM_WARM\": \"/\"")
    assert has.(plain, ~c"wrangler.durable.jsonc", "\"name\": \"app-durable\"")
    assert has.(plain, ~c"release/wrangler.jsonc", "\"workers_dev\": false")

    assert has.(
             plain,
             ~c"wrangler.jsonc",
             "\"version_metadata\": { \"binding\": \"BEAM_VERSION\" }"
           )

    assert has.(plain, ~c"wrangler.durable.jsonc", "\"version_metadata\"")
    assert has.(plain, ~c"wrangler.durable-global.jsonc", "\"main\": \"durable-global.js\"")
    assert has.(plain, ~c"wrangler.durable-global.jsonc", "\"BEAM_WARM\": \"/\"")

    # A Worker name has no "_": the app my_phoenix_app.
    named = files.(~c"my_phoenix_app", [:phoenix])
    assert has.(named, ~c"wrangler.durable.jsonc", "\"name\": \"my-phoenix-app-durable\"")
    assert has.(named, ~c"wrangler.durable.jsonc", "\"service\": \"my-phoenix-app-release\"")
    assert has.(named, ~c"release/wrangler.jsonc", "\"name\": \"my-phoenix-app-release\"")
    assert has.(named, ~c"wrangler.jsonc", "my-phoenix-app.SUBDOMAIN.workers.dev")
    assert ~c"my-app2" == :beam_com_wasm.worker_name(~c"My_App2")

    # Ecto SQLite: a snapshot at the boot point, and no warm-up request.
    sqlite = files.(~c"app", [:exqlite])
    assert "durable-global.js" == get.(~c"durable-global.js", sqlite)
    assert has.(sqlite, ~c"wrangler.global.jsonc", "--boot-point")
    assert has.(sqlite, ~c"wrangler.global.jsonc", "\"d1_databases\"")
    refute has.(sqlite, ~c"wrangler.global.jsonc", "BEAM_WARM")
    refute has.(sqlite, ~c"wrangler.durable-global.jsonc", "BEAM_WARM")
    assert has.(sqlite, ~c"wrangler.jsonc", "\"d1_databases\"")

    phoenix = files.(~c"app", [:phoenix])
    assert has.(phoenix, ~c"wrangler.jsonc", "\"PHX_HOST\": \"app.SUBDOMAIN.workers.dev\"")

    assert has.(
             phoenix,
             ~c"wrangler.global.jsonc",
             "\"BEAM_WARM\": \"/\", \"PHX_HOST\": \"app.SUBDOMAIN.workers.dev\""
           )
  end

  test "host_worker_test" do
    assert {:error, ~c"worker.js: no ~ts for the ~p host", ["from './beam.mjs'", :deno]} ==
             catch_throw(:beam_com_wasm.host_worker(:deno, "import wasm from './beam.wasm';"))
  end

  describe "page_files_test_" do
    # The worker.js of the Workers: the four imports that a module Web
    # Worker cannot resolve.
    @worker_js """
    import net from 'node:net';
    import wasm from './beam.wasm';
    const release = await import('./release.bin');
    const snapshot = await import('./snapshot.bin');
    """

    setup %{tmp_dir: dir} do
      root = root(dir)
      page = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"page"])
      :ok = :filelib.ensure_path(page)

      for f <- [~c"index.html", ~c"sw.js", ~c"vm.js", ~c"ws-shim.js", ~c"404.html"],
          do: :ok = :file.write_file(:filename.join(page, f), f)

      worker = [
        {~c"worker.js", @worker_js},
        {~c"browser.js", "browser.js"},
        {~c"browser/none.js", "none.js"},
        {~c"beam.mjs", "beam.mjs"},
        {~c"beam.wasm", "beam.wasm"},
        {~c"licenses/NOTICE", "notice"},
        {~c"wrangler.jsonc", "{}"},
        {~c"release/app.js", "app.js"}
      ]

      files = fn apps, rel_files ->
        rel = %{name: ~c"app", files: rel_files, apps: apps}

        for {f, d} <- :beam_com_wasm.page_files(rel, worker, root),
            do: {f, IO.iodata_to_binary(d)}
      end

      %{files: files}
    end

    # beam.wasm and release.bin are hard links (write_page/2).
    test "the files of the site", %{files: files} do
      page = files.([], [])

      assert Enum.sort(Enum.map(page, &elem(&1, 0))) ==
               Enum.sort([
                 ~c"index.html",
                 ~c"sw.js",
                 ~c"vm.js",
                 ~c"ws-shim.js",
                 ~c"404.html",
                 ~c"env.json",
                 ~c"worker.js",
                 ~c"browser.js",
                 ~c"browser/none.js",
                 ~c"beam.mjs",
                 ~c"licenses/NOTICE",
                 ~c"app/static.json"
               ])

      assert "[]" == :proplists.get_value(~c"app/static.json", page)
    end

    test "worker.js imports the modules of browser/", %{files: files} do
      js = :proplists.get_value(~c"worker.js", files.([], []))

      for spec <- ["'node:net'", "'./beam.wasm'", "'./release.bin'", "'./snapshot.bin'"],
          do: refute(js =~ spec)

      assert js =~ "import net from './browser/net.js'"
      assert js =~ "from './browser/beam-wasm.js'"
      assert js =~ "import('./browser/none.js')"
    end

    test "a worker.js with another import of beam.wasm" do
      assert {:error, ~c"worker.js: the ~p host cannot import ~ts", [:page, "'./beam.wasm'"]} ==
               catch_throw(:beam_com_wasm.page_worker("const w = new URL('./beam.wasm');"))
    end

    test "the variables of an app with no Phoenix", %{files: files} do
      assert %{"name" => "app", "env" => %{"PORT" => "4000", "HOME" => "/tmp"}, "secrets" => []} ==
               :json.decode(:proplists.get_value(~c"env.json", files.([], [])))
    end

    test "the variables of a Phoenix app with Ecto SQLite", %{files: files} do
      env = :json.decode(:proplists.get_value(~c"env.json", files.([:phoenix, :exqlite], [])))

      assert %{
               "PORT" => "4000",
               "HOME" => "/tmp",
               "PHX_SERVER" => "true",
               "PHX_HOST" => "localhost",
               "DATABASE_PATH" => "/tmp/app.db"
             } == env["env"]

      assert ["SECRET_KEY_BASE"] == env["secrets"]
    end

    test "the files of priv/static of the app, not the compressed copies and the dot files",
         %{files: files} do
      page =
        files.([], [
          {~c"lib/app-0.2.0/priv/static/assets/app.css", "css"},
          {~c"lib/app-0.2.0/priv/static/assets/app.css.gz", "gz"},
          {~c"lib/app-0.2.0/priv/static/favicon.ico", "ico"},
          {~c"lib/app-0.2.0/priv/static/.well-known/security.txt", "dot"},
          {~c"lib/app-0.2.0/priv/static/assets/.hidden.css", "dot"},
          {~c"lib/app-0.2.0/priv/other/x.txt", "x"},
          {~c"lib/app_web-1/priv/static/web.css", "web"},
          {~c"lib/app-0.2.0/ebin/app.app", "app"}
        ])

      assert ["/assets/app.css", "/favicon.ico"] ==
               :json.decode(:proplists.get_value(~c"app/static.json", page))

      assert "css" == :proplists.get_value(~c"app/assets/app.css", page)
      assert "ico" == :proplists.get_value(~c"app/favicon.ico", page)
      refute :proplists.is_defined(~c"app/assets/app.css.gz", page)
      # actions/upload-pages-artifact leaves out a name that starts with ".".
      refute :proplists.is_defined(~c"app/.well-known/security.txt", page)
      refute :proplists.is_defined(~c"app/assets/.hidden.css", page)
    end

    # A second build replaces the links of the first one.
    test "beam.wasm and release.bin of the page are hard links", %{tmp_dir: dir} do
      out = Path.join(dir, "out")
      File.mkdir_p!(Path.join(out, "release"))

      for _ <- 1..2 do
        File.write!(Path.join(out, "beam.wasm"), "wasm")
        File.write!(Path.join([out, "release", "release.bin"]), "release")
        :ok = :beam_com_wasm.write_page(String.to_charlist(out), [{~c"app/static.json", "[]"}])
      end

      for {page, file} <- [{"beam.wasm", "beam.wasm"}, {"release.bin", "release/release.bin"}] do
        assert File.stat!(Path.join([out, "page", page])).inode ==
                 File.stat!(Path.join(out, file)).inode
      end

      assert "[]" == File.read!(Path.join([out, "page", "app", "static.json"]))
    end
  end

  # release.bin: no debug information in the code, and the modules that the
  # boot does not load compressed (the loader of ERTS reads gzip).
  test "strip_and_compress_test" do
    a = beam(:a)
    b = beam(:b)
    gz = :zlib.gzip(a)

    files = [
      {~c"lib/x-1/ebin/a.beam", a},
      {~c"lib/x-1/ebin/b.beam", b},
      {~c"lib/x-1/ebin/c.beam", gz},
      {~c"lib/x-1/ebin/x.app", "app"}
    ]

    stripped = :beam_com_wasm.strip_beams(files)
    get = &:proplists.get_value/2
    assert :missing_chunk == chunk(get.(~c"lib/x-1/ebin/a.beam", stripped), ~c"Dbgi")
    assert <<_::binary>> = chunk(a, ~c"Dbgi")
    assert gz == get.(~c"lib/x-1/ebin/c.beam", stripped)
    assert "app" == get.(~c"lib/x-1/ebin/x.app", stripped)
    {packed, 1} = :beam_com_wasm.compress_beams(stripped, [:a])
    assert <<"FOR1", _::binary>> = get.(~c"lib/x-1/ebin/a.beam", packed)
    assert <<31, 139, _::binary>> = get.(~c"lib/x-1/ebin/b.beam", packed)

    try do
      {:module, :b} = :code.load_binary(:b, ~c"b.beam", get.(~c"lib/x-1/ebin/b.beam", packed))
      assert :ok == apply(:b, :f, [])
    after
      :code.purge(:b)
      :code.delete(:b)
    end

    assert {stripped, 0} == :beam_com_wasm.compress_beams(stripped, [])
  end

  # A .beam file of a release keeps its attributes: Ecto.Repo reads the
  # behaviours of its adapter. beam_lib:strip/1 removes them.
  test "strip_keeps_attributes_test" do
    {:ok, :m, beam} =
      :compile.forms(
        [
          {:attribute, 1, :module, :m},
          {:attribute, 2, :behaviour, :gen_server},
          {:attribute, 3, :export, [f: 0]},
          {:function, 4, :f, 0, [{:clause, 4, [], [], [{:atom, 4, :ok}]}]}
        ],
        [:binary, :debug_info]
      )

    s = :beam_com_wasm.strip(~c"lib/x-1/ebin/m.beam", beam)
    assert :missing_chunk == chunk(s, ~c"Dbgi")
    {:ok, {:m, [{:attributes, attrs}]}} = :beam_lib.chunks(s, [:attributes])
    assert [:gen_server] == :proplists.get_value(:behaviour, attrs)
    assert "text" == :beam_com_wasm.strip(~c"lib/x-1/priv/a.txt", "text")
  end

  # The module wasm of a wasm32 release: each function calls
  # wasm_host_wasm, which checks its arguments before it asks the host.
  test "wasm_shim_test" do
    {:module, :wasm} = :code.load_binary(:wasm, ~c"shim", :beam_com_wasm.wasm_shim())
    mod = :wasm

    try do
      assert function_exported?(:wasm, :run, 2)
      assert function_exported?(:wasm, :call_function, 3)

      assert :badarg ==
               error_of(fn -> mod.call_function({:wasm_instance, "i1"}, ~c"f", ["x"]) end)

      assert {:badarg, :host_functions_not_supported} ==
               error_of(fn -> mod.instantiate({:wasm_module, "m1"}, %{"env" => %{}}) end)
    after
      :code.purge(:wasm)
      :code.delete(:wasm)
    end
  end

  describe "with_wasm_test_" do
    setup do
      %{
        host: {~c"lib/wasm_host-0.1.0/ebin/wasm_host.app", "app"},
        shim: :beam_com_wasm.wasm_shim()
      }
    end

    test "no application wasm: the module goes into wasm_host", %{host: host, shim: shim} do
      assert [host, {~c"lib/wasm_host-0.1.0/ebin/wasm.beam", shim}] ==
               :beam_com_wasm.with_wasm([host])
    end

    test "the application wasm: its module (the NIF of WAMR) is replaced", %{
      host: host,
      shim: shim
    } do
      assert [host, {~c"lib/wasm-0.1.0/ebin/wasm.beam", shim}] ==
               :beam_com_wasm.with_wasm([host, {~c"lib/wasm-0.1.0/ebin/wasm.beam", "native"}])
    end
  end

  # The edge part of a native app.com (beam_com_build): the files of View
  # that the runtime changes or adds, under .wasm/.
  # The identity of a runtime is the SHA-256 of the output of
  # "sha256sum app-com.js beam.mjs beam.wasm worker.js": a person can
  # calculate it again with the shell. Each file here holds its own name.
  test "runtime_id_test_" do
    files = for f <- ~w(worker.js beam.wasm app-com.js beam.mjs)c, do: {f, List.to_string(f)}

    assert "8202813e4be300cab28f6919fed813c06bb603967052a5e3cfc04fdaff402afe" ==
             :beam_com_wasm.runtime_id(files)

    # A change of each file is another runtime.
    for {f, _} <- files do
      other = :lists.keyreplace(f, 1, files, {f, "changed"})
      assert :beam_com_wasm.runtime_id(other) != :beam_com_wasm.runtime_id(files)
    end
  end

  describe "overlay_test_" do
    # The runtime of the edge part comes only from the zip (root/): not
    # from BEAM_COM_WASM_RUNTIME (step unit sets it) or the cache.
    setup %{tmp_dir: dir} do
      old_cache = System.get_env("BEAM_COM_CACHE")
      old_runtime = System.get_env("BEAM_COM_WASM_RUNTIME")
      System.put_env("BEAM_COM_CACHE", Path.join(dir, "empty-cache"))
      System.delete_env("BEAM_COM_WASM_RUNTIME")

      on_exit(fn ->
        restore_env("BEAM_COM_WASM_RUNTIME", old_runtime)
        restore_env("BEAM_COM_CACHE", old_cache)
      end)

      root = root(dir)
      host = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv"])
      :ok = :filelib.ensure_path(:filename.join(host, ~c"worker"))
      :ok = :filelib.ensure_path(:filename.join(host, ~c"runtime"))
      :ok = :file.write_file(:filename.join([host, ~c"worker", ~c"worker.js"]), "worker")
      :ok = :file.write_file(:filename.join([host, ~c"worker", ~c"app-com.js"]), "reader")
      :ok = :file.write_file(:filename.join([host, ~c"runtime", ~c"beam.wasm"]), "runtime")
      :ok = :file.write_file(:filename.join([host, ~c"runtime", ~c"beam.mjs"]), "loader")
      mod = :"Elixir.Exqlite.Sqlite3NIF"

      {:ok, ^mod, nif} =
        :compile.forms(
          [
            {:attribute, 1, :module, mod},
            {:attribute, 1, :export, [load_nif: 0]},
            {:function, 1, :load_nif, 0, [{:clause, 1, [], [], [{:atom, 1, :native}]}]}
          ],
          [:binary]
        )

      app = fn a, v -> :io_lib.format(~c"~p.~n", [{:application, a, [vsn: v]}]) end

      view = [
        {~c"releases/1/start.boot", boot()},
        {~c"releases/1/vm.args", "-noshell\n"},
        {~c"lib/app-1/ebin/app.app", app.(:app, ~c"1")},
        {~c"lib/exqlite-0.41.0/ebin/exqlite.app", app.(:exqlite, ~c"0.41.0")},
        {~c"lib/exqlite-0.41.0/ebin/Elixir.Exqlite.Sqlite3NIF.beam", nif}
      ]

      %{root: root, view: view, rel: %{name: ~c"app", vsn: ~c"1", kind: :beam_com}}
    end

    test "the files that the runtime changes or adds", %{root: root, view: view, rel: rel} do
      edge = :beam_com_wasm.overlay(view, view, rel, %{root: root})
      names = for {p, _} <- edge, do: p

      for p <- [
            ~c".wasm/.release.json",
            ~c".wasm/releases/1/start.boot",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm_host.app",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm_tcp.beam",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm.beam",
            ~c".wasm/lib/exqlite-0.41.0/ebin/Elixir.Exqlite.Sqlite3NIF.beam"
          ] do
        assert p in names, "#{p}"
      end

      # The files that the runtime reads as they are.
      refute ~c".wasm/lib/app-1/ebin/app.app" in names
      refute ~c".wasm/releases/1/vm.args" in names
      assert ~c".wasm/.release.json" == hd(names)

      meta =
        :json.decode(IO.iodata_to_binary(:proplists.get_value(~c".wasm/.release.json", edge)))

      assert %{"name" => "app", "vsn" => "1", "sql" => true} = meta

      assert meta["runtime"] ==
               :beam_com_wasm.runtime_id([
                 {~c"worker.js", "worker"},
                 {~c"app-com.js", "reader"},
                 {~c"beam.mjs", "loader"},
                 {~c"beam.wasm", "runtime"}
               ])
    end

    # A file of View that differs from the native file: the runtime gets
    # the file of View (a Mix release in beam_com_build).
    test "a file of the release that the native file changes", %{root: root, view: view, rel: rel} do
      native =
        :lists.keyreplace(~c"releases/1/vm.args", 1, view, {~c"releases/1/vm.args", "native"})

      edge = :beam_com_wasm.overlay(view, native, rel, %{root: root})
      assert "-noshell\n" == :proplists.get_value(~c".wasm/releases/1/vm.args", edge)
    end

    test "--cacerts: etc/cacerts.pem", %{root: root, view: view, rel: rel, tmp_dir: dir} do
      %{cert: der} = :public_key.pkix_test_root_cert(~c"beam_com test root", [])
      pem = String.to_charlist(Path.join(dir, "roots.pem"))
      :ok = :file.write_file(pem, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
      edge = :beam_com_wasm.overlay(view, view, rel, %{root: root, cacerts: pem})
      assert List.keymember?(edge, ~c".wasm/etc/cacerts.pem", 0)

      meta =
        :json.decode(IO.iodata_to_binary(:proplists.get_value(~c".wasm/.release.json", edge)))

      assert "/app/etc/cacerts.pem" in Enum.map(meta["args"], &String.trim(&1, "\""))
    end

    # A release with its own module of wasm_host: no edge part, and a
    # warning (the native file does not change).
    test "a release that has a module of wasm_host", %{root: root, view: view, rel: rel} do
      own = view ++ [{~c"lib/app-1/ebin/wasm_tcp.beam", "own"}]

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert [] == :beam_com_wasm.overlay(own, own, rel, %{root: root})
        end)

      assert out =~ "warning: no WebAssembly part: lib/app-1/ebin/wasm_tcp.beam"
      assert [] == :beam_com_wasm.overlay(own, own, rel, %{root: root, quiet: true})
    end

    test "no worker.js or no runtime: no edge part", %{root: root, view: view, rel: rel} do
      runtime = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"runtime"])
      worker = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"worker"])
      :ok = :file.del_dir_r(runtime)
      assert :none == :beam_com_wasm.edge_runtime(root)
      assert [] == :beam_com_wasm.overlay(view, view, rel, %{root: root})
      :ok = :file.del_dir_r(worker)
      assert :none == :beam_com_wasm.edge_runtime(root)
    end
  end

  # A module in place of the NIF of exqlite: the exports of the original,
  # calls to wasm_host_sqlite:dispatch/2 (with no NIF of exqlite: the host),
  # and not_supported for the functions that the backend does not have.
  test "sqlite_shim_test" do
    mod = :"Elixir.Exqlite.Sqlite3NIF"

    forms = [
      {:attribute, 1, :module, mod},
      {:attribute, 1, :export, [load_nif: 0, open: 2, made_up: 1]},
      {:function, 1, :load_nif, 0, [{:clause, 1, [], [], [{:atom, 1, :native}]}]},
      {:function, 1, :open, 2,
       [{:clause, 1, [{:var, 1, :_}, {:var, 1, :_}], [], [{:atom, 1, :native}]}]},
      {:function, 1, :made_up, 1, [{:clause, 1, [{:var, 1, :_}], [], [{:atom, 1, :native}]}]}
    ]

    {:ok, ^mod, original} = :compile.forms(forms, [:binary])
    bin = :beam_com_wasm.sqlite_shim(original)
    {:module, ^mod} = :code.load_binary(mod, ~c"shim", bin)

    try do
      assert :ok == apply(mod, :load_nif, [])
      if :ets.info(:wasm_host_sqlite) == :undefined, do: :wasm_host_sqlite.table()
      # The shim answers, not the NIF.
      assert {:ok, {:wasm_sqlite, _}} = apply(mod, :open, [~c"db", []])
      assert :not_supported == error_of(fn -> apply(mod, :made_up, [:x]) end)
    after
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  # The file nifs of the runtime: the hex.pm packages whose NIFs it has.
  test "runtime_nifs_test", %{tmp_dir: tmp} do
    dir = String.to_charlist(Path.join(tmp, "beam_com_wasm_nifs"))
    :ok = :filelib.ensure_path(dir)
    _ = :file.delete(:filename.join(dir, ~c"nifs"))
    assert [] == :beam_com_wasm.runtime_nifs(dir)

    :ok =
      :file.write_file(
        :filename.join(dir, ~c"nifs"),
        "bcrypt_elixir 3.3.2\nargon2_elixir 4.1.3\n"
      )

    assert [:bcrypt_elixir, :argon2_elixir] == :beam_com_wasm.runtime_nifs(dir)
  end

  # The boot script of a release "app" 1, with kernel, stdlib and app, and
  # the commands after_stdlib between stdlib and app.
  defp boot(after_stdlib \\ []) do
    :erlang.term_to_binary(
      {:script, {~c"app", ~c"1"},
       [
         {:preLoaded, [:init]},
         {:path, [~c"$ROOT/lib/kernel-1/ebin", ~c"$ROOT/lib/stdlib-2/ebin"]},
         {:primLoad, [:lists]},
         {:kernel_load_completed},
         {:path, [~c"$ROOT/lib/kernel-1/ebin"]},
         {:primLoad, [:gen_tcp]},
         {:path, [~c"$ROOT/lib/stdlib-2/ebin"]},
         {:primLoad, [:maps]},
         {:apply, {:application, :start_boot, [:kernel, :permanent]}},
         {:apply, {:application, :start_boot, [:stdlib, :permanent]}}
       ] ++ after_stdlib ++ [{:apply, {:application, :start_boot, [:app, :permanent]}}]}
    )
  end

  defp commands(files) do
    {_, boot} = List.keyfind(files, ~c"releases/1/start.boot", 0)
    {:script, _, cmds} = :erlang.binary_to_term(boot)
    cmds
  end

  # A zip of beam.com with the application wasm_host, in a new directory.
  defp root(dir) do
    root = String.to_charlist(Path.join(dir, "beam_com_wasm_root"))
    ebin = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"ebin"])
    :ok = :filelib.ensure_path(ebin)

    :ok =
      :file.write_file(
        :filename.join(ebin, ~c"wasm_host.app"),
        :io_lib.format(~c"~p.~n", [{:application, :wasm_host, [vsn: ~c"0.1.0"]}])
      )

    {:ok, :wasm_tcp, beam} = :compile.forms([{:attribute, 1, :module, :wasm_tcp}], [:binary])
    :ok = :file.write_file(:filename.join(ebin, ~c"wasm_tcp.beam"), beam)
    root
  end

  # A module M with f() -> ok, with debug information.
  defp beam(m) do
    {:ok, ^m, bin} =
      :compile.forms(
        [
          {:attribute, 1, :module, m},
          {:attribute, 2, :export, [f: 0]},
          {:function, 3, :f, 0, [{:clause, 3, [], [], [{:atom, 3, :ok}]}]}
        ],
        [:binary, :debug_info]
      )

    bin
  end

  defp chunk(bin, c) do
    {:ok, {_, [{_, v}]}} = :beam_lib.chunks(bin, [c], [:allow_missing_chunks])
    v
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # The reason of an Erlang error, as erlang:error/1 gave it.
  defp error_of(fun) do
    fun.()
    flunk("no error")
  catch
    :error, reason -> reason
  end
end
