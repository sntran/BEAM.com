defmodule BeamCom.WasmDiffTest do
  @moduledoc """
  The differential test: each program of tests/wasm_diff runs in the
  native Erlang/OTP and in the WebAssembly runtime of --target wasm32,
  and the two outputs must be the same.

  The test needs BEAM_COM_WASM_RUNTIME (the directory of the Worker
  build of beam.wasm, as build/wasm-runtime) and Node.js with JSPI
  (Node.js 25 or later). The runtime must come from the same OTP as
  the erl of the test. tests/wasm_diff/run.mjs runs one program in
  the runtime, with the schedule of Node.js or of a plain Worker.
  """
  use ExUnit.Case, async: true

  @moduletag :node
  @moduletag :wasm_diff
  @moduletag timeout: 300_000

  @dir Path.join(__DIR__, "wasm_diff")
  @programs @dir
            |> Path.join("diff_*.erl")
            |> Path.wildcard()
            |> Enum.map(&Path.basename(&1, ".erl"))

  setup_all do
    top = Path.join([File.cwd!(), "tmp", "wasm_diff", "#{System.unique_integer([:positive])}"])
    ebin = Path.join(top, "ebin")
    File.mkdir_p!(ebin)

    for file <- Path.wildcard(Path.join(@dir, "diff_*.erl")) do
      {:ok, _} =
        :compile.file(String.to_charlist(file), [
          :report,
          :warnings_as_errors,
          outdir: String.to_charlist(ebin)
        ])
    end

    {erl, root, libs} = otp(top)

    native =
      @programs
      |> Task.async_stream(&native(erl, ebin, top, &1), timeout: 120_000, ordered: true)
      |> Enum.zip_with(@programs, fn {:ok, out}, name -> {name, out} end)
      |> Map.new()

    %{top: top, ebin: ebin, root: root, libs: libs, native: native}
  end

  for program <- @programs, schedule <- ["node", "plain"] do
    @tag program: program, schedule: schedule
    test "#{program} in wasm (schedule #{schedule})", ctx do
      {wasm_out, wasm_status} = wasm(ctx, ctx.program, ctx.schedule)
      {native_out, native_status} = Map.fetch!(ctx.native, ctx.program)
      assert lines(wasm_out) == lines(native_out)
      assert wasm_status == native_status
    end
  end

  # A NIF library in WebAssembly (docs/NIFS.md): the engine of the host
  # runs priv/nif_check.wasm of tests/programs/nif_check. The native erl
  # of the test can be one with no loader, so the test only checks the
  # output of the runtime.
  test "the NIF library in WebAssembly of nif_check", ctx do
    {out, status} = nif_check(ctx, "nif_check", false)
    assert out =~ ~r/^nif_check: all \d+ passed$/m
    assert status == 0
  end

  # As a Worker: the module compiled from nifs/0.wasm of nif_files/1, and
  # no compilation of WebAssembly at run time.
  test "the NIF library in WebAssembly of nif_check, compiled as for a Worker", ctx do
    {out, status} = nif_check(ctx, "nif_check_worker", true)
    assert out =~ ~r/^nif_check: all \d+ passed$/m
    assert status == 0
  end

  # A snapshot while the program waits, with the library loaded: the new
  # instance gets the memory of the library again (Module.nifHost), and the
  # second run of the checks passes there.
  test "the NIF library in WebAssembly of nif_check, after a snapshot", ctx do
    eval = "nif_check:main([]), receive after 1500 -> ok end, nif_check:main([]), halt()."
    {out, status} = nif_check(ctx, "nif_check_snapshot", false, %{snapshot: true, eval: eval})
    assert [_, _] = Regex.scan(~r/^nif_check: all \d+ passed$/m, out)
    assert status == 0
  end

  # A crash dump (EM7 in docs/UPSTREAM.md): the dump of the runtime is
  # whole, as the native one. The native run of setup_all wrote its dump.
  test "the crash dump of diff_halt is whole, in wasm and natively", ctx do
    dump = Path.join([ctx.top, "wasm-dump", "erl_crash.dump"])
    File.mkdir_p!(Path.dirname(dump))
    {_, status} = wasm(ctx, "diff_halt", "node", %{out: %{"/work/erl_crash.dump" => dump}})
    assert status == 1

    for file <- [dump, Path.join([ctx.top, "native", "diff_halt", "erl_crash.dump"])] do
      text = File.read!(file)
      assert text =~ ~r/\A=erl_crash_dump:/
      assert text =~ "\nSlogan: diff_halt: a crash dump\n"
      assert text =~ ~r/\nCalling Thread: scheduler:\d+\n/
      assert String.ends_with?(String.trim_trailing(text), "\n=end")
    end
  end

  defp nif_check(ctx, name, compiled, job \\ %{}) do
    src = Path.join([__DIR__, "programs", "nif_check"])
    app = Path.join([ctx.top, name, "nif_check"])
    ebin = Path.join(app, "ebin")
    file = Path.join([app, "priv", "nif_check.wasm"])
    File.mkdir_p!(ebin)
    File.mkdir_p!(Path.dirname(file))

    for erl <- Path.wildcard(Path.join([src, "src", "*.erl"])) do
      {:ok, _} =
        :compile.file(String.to_charlist(erl), [:report, outdir: String.to_charlist(ebin)])
    end

    bytes = File.read!(Path.join([src, "priv", "nif_check.wasm"]))
    File.write!(file, bytes)

    nifs =
      if compiled do
        [_js, {_, module}] = :beam_com_wasm.nif_files([{~c"lib/nif_check/priv/x.wasm", bytes}])
        compiled_file = Path.join([ctx.top, name, "nif_check.module.wasm"])
        File.write!(compiled_file, module)
        %{file => compiled_file}
      end

    job = if nifs, do: Map.put(job, :nifs, nifs), else: job
    # The work directory has the name of the test, and the program is nif_check.
    job = Map.put_new(job, :eval, eval("nif_check", "/work"))
    wasm(%{ctx | libs: [app | ctx.libs], ebin: ebin}, name, "node", job)
  end

  # The command of the native erl, the OTP root, and the ebin directories
  # of the runtime. Under beam.com, the root is /zip, which is not on the
  # disk: the test copies the boot file and the ebin directories out of
  # it, and runs beam.com in erl mode.
  defp otp(top) do
    apps = [:kernel, :stdlib, :crypto]

    case :init.get_argument(:beam_com_exe) do
      {:ok, [[exe]]} ->
        root = Path.join(top, "otp")
        File.mkdir_p!(Path.join(root, "bin"))
        boot = Path.join([List.to_string(:code.root_dir()), "bin", "start_clean.boot"])
        File.write!(Path.join([root, "bin", "start_clean.boot"]), File.read!(boot))

        libs =
          for app <- apps do
            dir = Path.join([root, "lib", "#{app}-#{Application.spec(app, :vsn)}", "ebin"])
            copy_dir(Path.join(List.to_string(:code.lib_dir(app)), "ebin"), dir)
            dir
          end

        {{List.to_string(exe), [{"BEAM_COM_ERL", "1"}]}, root, libs}

      _ ->
        root = List.to_string(:code.root_dir())
        libs = for app <- apps, do: Path.join(List.to_string(:code.lib_dir(app)), "ebin")
        {{Path.join([root, "bin", "erl"]), []}, root, libs}
    end
  end

  # Copies the files of the directory with the file calls of the VM, which
  # also read /zip.
  defp copy_dir(from, to) do
    File.mkdir_p!(to)

    for name <- File.ls!(from) do
      File.write!(Path.join(to, name), File.read!(Path.join(from, name)))
    end
  end

  defp native({erl, env}, ebin, top, program) do
    work = Path.join([top, "native", program])
    File.mkdir_p!(work)
    # A UTF-8 locale, as the runtime has: the encoding of standard_io
    # comes from it.
    run([erl, "-noshell", "-pa", ebin, "-eval", eval(program, work)], Path.join(work, "stderr"),
      env: [{"LC_ALL", "C.UTF-8"} | env],
      cd: work
    )
  end

  defp wasm(ctx, program, schedule, extra \\ %{}) do
    work = Path.join([ctx.top, "wasm-#{schedule}", program])
    File.mkdir_p!(work)

    job = %{
      runtime: System.fetch_env!("BEAM_COM_WASM_RUNTIME"),
      root: ctx.root,
      boot: Path.join([ctx.root, "bin", "start_clean.boot"]),
      libs: ctx.libs,
      pa: ctx.ebin,
      work: "/work",
      schedule: schedule,
      eval: eval(program, "/work")
    }

    job = Map.merge(job, extra)

    file = Path.join(work, "job.json")
    File.write!(file, :json.encode(job))
    node = System.find_executable("node")
    run([node, Path.join(@dir, "run.mjs"), file], Path.join(work, "stderr"), cd: work)
  end

  defp eval(program, dir), do: "#{program}:main([\"#{dir}\"]), halt()."

  # Runs the command with its stderr in a file, so that the output of the
  # test stays clean.
  defp run([cmd | args], stderr, opts) do
    env = [{"STDERR_FILE", stderr} | Keyword.get(opts, :env, [])]
    script = ~S(exec "$0" "$@" 2>"$STDERR_FILE")
    System.cmd("sh", ["-c", script, cmd | args], Keyword.merge(opts, env: env))
  end

  defp lines(text), do: String.split(text, "\n")
end
