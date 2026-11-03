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

    for file <- Path.wildcard(Path.join(@dir, "*.erl")) do
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

  # The ports to bindings of worker.js (docs/WORKERS.md, "Ports to
  # bindings"), with the port programs of run.mjs, and their flow control
  # in the two directions (tests/wasm_diff/port_check.erl).
  test "port_check: ports to bindings, with flow control", ctx do
    ports = %{"ECHO" => "echo", "SINK" => "sink", "SOURCE" => "source"}
    {out, status} = wasm(ctx, "port_check", "node", %{ports: ports})

    assert out ==
             """
             echo: the same bytes true
             sink: the same bytes true
             sink: the sends waited for the port true
             sink: exit 0
             source: the same bytes true
             source: the port waited for the reads of the VM true
             source: exit 0
             """

    assert status == 0
  end

  # Issue 141: the memory of the VM over the cases of
  # tests/wasm_diff/mem_check.erl (renders, binaries of 16 MB, a heap that
  # shrinks, a binary that grows, 16 processes at one time). After the
  # first run of a case, the memory of the VM (wasm_host:memory/0) must
  # stay near the same when the case runs again. Before the mmap() of ERTS
  # for Emscripten (wasm/erts/otp.patch), the unmap of most carriers
  # failed, and the memory grew with each run. A process keeps 8 MB of data
  # during all the cases, and it must be the same at the end. The run with
  # a snapshot restores the VM after the first case, so carriers of before
  # the snapshot end after it. The program waits after that case, so the
  # threads of ERTS return for the snapshot. The run with -Mea min has no
  # carriers.
  # Three runs with the default flags: when the unmap of the start of a
  # block freed the whole block, the split segments of the cache of
  # erl_mseg.c broke the memory in about 5 runs of 6 (EM9 in
  # docs/UPSTREAM.md).
  for run <- 1..3 do
    @tag timeout: 900_000
    @tag run: run
    test "the memory of the VM stays flat over the cases of mem_check (run #{run})", ctx do
      out = mem_check(ctx, "mem_check_#{ctx.run}", %{})
      assert out =~ ~r/^mem_check: erlang_memory \d+$/m
    end
  end

  @tag timeout: 900_000
  test "the memory of the VM stays flat over the cases of mem_check, after a snapshot", ctx do
    mem_check(ctx, "mem_check_snapshot", %{snapshot: true, args: "[pause]"})
  end

  @tag timeout: 900_000
  test "the memory of the VM stays flat over the cases of mem_check, with -Mea min", ctx do
    out = mem_check(ctx, "mem_check_mea_min", %{flags: ["-Mea", "min"]})
    assert out =~ ~r/^mem_check: erlang_memory none$/m
  end

  # Each case may grow the size of the memory (wasm_host:memory/0) and the
  # memory that malloc() gives out (wasm_host:memory(used)) by less than
  # 8 MB. Before the runtime had no cache of segments (+MMmcs 0, EM9 in
  # docs/UPSTREAM.md), heap_shrink grew the size by 0 to 32 MB, in steps
  # of 8 MB, and the cache kept these blocks from malloc(). With no cache,
  # each case was flat here, and the peak of the run was 74 MB in place of
  # 162 MB.
  @mem_limit 8 * 1024 * 1024
  @mem_cases ~w(renders big_binaries heap_shrink binary_growth parallel)

  defp mem_check(ctx, name, job) do
    ebin = Path.join([ctx.top, name, "ebin"])
    File.mkdir_p!(ebin)
    File.cp!(Path.join(ctx.ebin, "mem_check.beam"), Path.join(ebin, "mem_check.beam"))
    src = Path.join([__DIR__, "..", "src", "wasm_host", "wasm_host.erl"])
    {:ok, _} = :compile.file(String.to_charlist(src), [:report, outdir: String.to_charlist(ebin)])
    {args, job} = Map.pop(job, :args, "[]")
    job = Map.put(job, :eval, "mem_check:main(#{args}), halt().")
    # The crash dump of the VM, when it stops with one (mem_check sets
    # ERL_CRASH_DUMP).
    dump = Path.join([ctx.top, "wasm-node", name, "erl_crash.dump"])
    job = Map.put(job, :out, %{"/work/erl_crash.dump" => dump})
    {out, status} = wasm(%{ctx | ebin: ebin}, name, "node", job)
    # The stderr of the VM (wasm/4 writes it to a file), for the messages.
    err = File.read!(Path.join([ctx.top, "wasm-node", name, "stderr"]))
    out = out <> "stderr:\n" <> String.slice(err, -4000, 4000) <> crash_summary(dump)
    assert status == 0, out

    for c <- @mem_cases do
      [_, first, last] =
        Regex.run(~r/^mem_check: #{c} (\d+) (\d+)$/m, out) || flunk("no #{c}: #{out}")

      growth = String.to_integer(last) - String.to_integer(first)

      assert growth < @mem_limit,
             "#{c}: the memory of the VM grew #{div(growth, 1024)} KB: #{out}"

      [_, used_first, used_last] =
        Regex.run(~r/^mem_check: #{c} used (\d+) (\d+) \d+$/m, out) ||
          flunk("no #{c} used: #{out}")

      used = String.to_integer(used_last) - String.to_integer(used_first)
      assert used < @mem_limit, "#{c}: the memory in use grew #{div(used, 1024)} KB: #{out}"
    end

    assert out =~ ~r/^mem_check: keeper ok$/m
    out
  end

  # The slogan and the current process of a crash dump, for the message
  # of a failed test.
  defp crash_summary(dump) do
    case File.read(dump) do
      {:ok, text} ->
        lines = String.split(text, "\n")
        head = Enum.take(lines, 12)

        stack =
          lines
          |> Enum.drop_while(&(not String.starts_with?(&1, "Current Process")))
          |> Enum.take(40)

        Enum.join(["crash dump:" | head ++ ["..." | stack]], "\n")

      {:error, _} ->
        ""
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
