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

    root = List.to_string(:code.root_dir())

    libs =
      for app <- [:kernel, :stdlib, :crypto],
          do: Path.join(List.to_string(:code.lib_dir(app)), "ebin")

    native =
      @programs
      |> Task.async_stream(&native(root, ebin, top, &1), timeout: 120_000, ordered: true)
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

  defp native(root, ebin, top, program) do
    work = Path.join([top, "native", program])
    File.mkdir_p!(work)
    erl = Path.join([root, "bin", "erl"])
    # A UTF-8 locale, as the runtime has: the encoding of standard_io
    # comes from it.
    run([erl, "-noshell", "-pa", ebin, "-eval", eval(program, work)], Path.join(work, "stderr"),
      env: [{"LC_ALL", "C.UTF-8"}],
      cd: work
    )
  end

  defp wasm(ctx, program, schedule) do
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
