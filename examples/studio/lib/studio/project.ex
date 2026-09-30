defmodule Studio.Project do
  @moduledoc """
  The project of the studio: one Phoenix app in a directory of the VM.

  The server makes the project with the generator of phx_new
  (`mix phx.new`), compiles it with `Kernel.ParallelCompiler`, and starts
  it. It reads `mix.exs` and the config files with Mix, as `mix phx.server`
  does, but Mix does not build: the packages of the project are the
  applications of the release.

  Each change of state goes to the topic "project" of `Studio.PubSub`, as
  `{:project, info}`.
  """
  use GenServer
  require Logger

  @topic "project"
  # The directories and files that the file list does not show.
  @hidden ~w(_build deps .git .elixir_ls node_modules)
  # The Mix tasks of the studio: the generators of Phoenix and Ecto. They
  # only write files.
  @tasks ~w(phx.gen.html phx.gen.live phx.gen.json phx.gen.context phx.gen.schema
            phx.gen.embedded phx.gen.channel phx.gen.socket phx.gen.presence
            phx.gen.secret ecto.gen.migration)
  # The largest file that the editor opens.
  @max_read 1_000_000

  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The state of the project: a map for the page of the studio."
  def info, do: GenServer.call(__MODULE__, :info)

  @doc "Makes a new project NAME with `mix phx.new`, then builds it."
  def new(name), do: GenServer.call(__MODULE__, {:new, name}, :infinity)

  @doc "Compiles the project again and starts it again."
  def build, do: GenServer.call(__MODULE__, :build, :infinity)

  @doc "The files of the project, as paths relative to its directory."
  def files, do: GenServer.call(__MODULE__, :files)

  def read(path), do: GenServer.call(__MODULE__, {:read, path})

  @doc "Writes a file of the project. It does not build."
  def write(path, content), do: GenServer.call(__MODULE__, {:write, path, content})

  @doc """
  Runs one Mix task of the list in the project, as `mix TASK ARGS`, then
  builds. It gives {:ok, lines} or {:error, lines}, the output of the task.
  """
  def mix(line), do: GenServer.call(__MODULE__, {:mix, line}, :infinity)

  @doc "The directory of the project, or nil."
  def dir, do: :persistent_term.get({__MODULE__, :dir}, nil)

  @doc "The endpoint of the running app, or nil. The front plug reads it for each request."
  def endpoint, do: :persistent_term.get({__MODULE__, :endpoint}, nil)

  @doc "The path of the site (for example /t/NAME), or an empty text."
  def base, do: :persistent_term.get({__MODULE__, :base}, "")

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    File.mkdir_p!(root)
    :persistent_term.put({__MODULE__, :base}, Keyword.get(opts, :base, ""))

    state = %{
      root: root,
      dir: nil,
      app: nil,
      status: :empty,
      message: nil,
      diagnostics: [],
      log: [],
      modules: [],
      compiled_ms: nil
    }

    # A project that is already in the directory (a restart of the VM with
    # the same files) starts again.
    case existing(root) do
      nil -> {:ok, state}
      dir -> {:ok, state, {:continue, {:open, dir}}}
    end
  end

  @impl true
  def handle_continue({:open, dir}, state) do
    {:noreply, state |> open(dir) |> do_build()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info(state), state}

  def handle_call({:new, name}, _from, state) do
    with :ok <- check_name(name),
         dir = Path.join(state.root, name),
         :ok <- check_absent(dir) do
      state =
        state |> stop_app() |> set(status: :generating, log: [], diagnostics: [], message: nil)

      state = %{state | log: generate(dir)}

      if File.regular?(Path.join(dir, "mix.exs")) do
        state = state |> open(dir) |> do_build()
        {:reply, :ok, state}
      else
        state = set(state, status: :error, message: "mix phx.new did not make the project.")
        {:reply, {:error, state.message}, state}
      end
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call(:build, _from, %{dir: nil} = state),
    do: {:reply, {:error, "No project."}, state}

  def handle_call(:build, _from, state) do
    state = do_build(state)
    {:reply, if(state.status == :running, do: :ok, else: {:error, state.message}), state}
  end

  def handle_call({:mix, _line}, _from, %{dir: nil} = state),
    do: {:reply, {:error, ["No project."]}, state}

  def handle_call({:mix, line}, _from, state) do
    case OptionParser.split(line) do
      [task | args] when task in @tasks ->
        {result, lines} = run_task(state.dir, task, args)
        lines = ["$ mix " <> line | lines]

        case result do
          :ok ->
            state = do_build(state)
            {:reply, {:ok, lines}, state}

          {:error, message} ->
            {:reply, {:error, lines ++ ["** " <> message]}, state}
        end

      _ ->
        {:reply,
         {:error, ["$ mix " <> line, "The studio runs these tasks: " <> Enum.join(@tasks, ", ")]},
         state}
    end
  end

  def handle_call(:files, _from, %{dir: nil} = state), do: {:reply, [], state}
  def handle_call(:files, _from, state), do: {:reply, list_files(state.dir), state}

  def handle_call({:read, path}, _from, state) do
    reply =
      with {:ok, full} <- resolve(state, path),
           {:ok, %{size: size, type: :regular}} <- File.stat(full),
           true <- size <= @max_read || {:error, :too_large},
           {:ok, text} <- File.read(full),
           true <- String.valid?(text) || {:error, :binary} do
        {:ok, text}
      else
        {:ok, _} -> {:error, :not_a_file}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:write, path, content}, _from, state) do
    reply =
      with {:ok, full} <- resolve(state, path),
           :ok <- File.mkdir_p(Path.dirname(full)) do
        File.write(full, content)
      end

    {:reply, reply, state}
  end

  # The name of a new project: the name of an OTP application.
  defp check_name(name) do
    if is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_]{0,39}$/, name) and
         name not in ~w(studio phoenix elixir mix test) do
      :ok
    else
      {:error, "A name has a lower-case letter first, then lower-case letters, digits or _."}
    end
  end

  defp check_absent(dir) do
    if File.exists?(dir),
      do: {:error, "The project #{Path.basename(dir)} is already here."},
      else: :ok
  end

  # A path of the project: relative, with no "..".
  defp resolve(%{dir: nil}, _path), do: {:error, :no_project}

  defp resolve(state, path) when is_binary(path) do
    parts = Path.split(path)

    if path == "" or Path.type(path) != :relative or ".." in parts or
         Enum.any?(parts, &(&1 in @hidden)) do
      {:error, :invalid_path}
    else
      {:ok, Path.join(state.dir, path)}
    end
  end

  defp existing(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.find(&File.regular?(Path.join(&1, "mix.exs")))

      _ ->
        nil
    end
  end

  defp open(state, dir) do
    :persistent_term.put({__MODULE__, :dir}, dir)
    %{state | dir: dir}
  end

  ## Generate

  defp generate(dir) do
    Mix.shell(Mix.Shell.Process)

    args =
      [dir, "--database", "sqlite3", "--no-install", "--no-version-check"] ++
        ~w(--no-mailer --no-dashboard --no-gettext)

    result =
      try do
        Mix.Tasks.Phx.New.run(args)
        :ok
      rescue
        e -> {:error, Exception.message(e)}
      after
        Mix.shell(Mix.Shell.IO)
      end

    lines = shell_lines([])
    lines = ["$ mix phx.new " <> Enum.join([Path.basename(dir) | tl(args)], " ") | lines]

    case result do
      :ok -> lines
      {:error, message} -> lines ++ ["** " <> message]
    end
  end

  defp run_task(dir, task, args) do
    Mix.shell(Mix.Shell.Process)

    result =
      try do
        Mix.Project.in_project(String.to_atom(Path.basename(dir)), dir, fn _ ->
          Mix.Task.rerun(task, args)
        end)

        :ok
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, "exit: " <> inspect(reason)}
      after
        Mix.shell(Mix.Shell.IO)
      end

    {result, shell_lines([])}
  end

  # The output of Mix.Shell.Process, in order.
  defp shell_lines(acc) do
    receive do
      {:mix_shell, _kind, [text]} -> shell_lines([String.trim_trailing(text) | acc])
      {:mix_shell, :yes?, [text]} -> shell_lines([String.trim_trailing(text) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Build

  defp do_build(state) do
    state = state |> stop_app() |> set(status: :compiling, message: nil, diagnostics: [])
    started = System.monotonic_time(:millisecond)

    result =
      try do
        compile_and_start(state)
      rescue
        e -> {:error, Exception.message(e), []}
      catch
        kind, reason -> {:error, Exception.format(kind, reason), []}
      end

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, app, endpoint, modules, diagnostics} ->
        :persistent_term.put({__MODULE__, :endpoint}, endpoint)
        Logger.info("studio: #{app} runs, built in #{ms} ms")

        set(state,
          status: :running,
          app: app,
          modules: modules,
          diagnostics: diagnostics,
          compiled_ms: ms
        )

      {:error, message, diagnostics} ->
        set(state, status: :error, message: message, diagnostics: diagnostics, compiled_ms: ms)
    end
  end

  defp compile_and_start(state) do
    dir = state.dir

    # Mix reads mix.exs and gives the paths of the build, as for `mix compile`.
    Mix.Project.in_project(String.to_atom(Path.basename(dir)), dir, fn module ->
      config = Mix.Project.config()
      app = config[:app]

      application =
        if function_exported?(module, :application, 0), do: module.application(), else: []

      app_config = read_config(app, dir)
      apply_config(app, app_config)
      deps = runtime_deps(config[:deps] || [])
      Enum.each(deps, &Application.load/1)

      ebin = Mix.Project.compile_path()
      purge(state.modules)
      File.rm_rf!(ebin)
      File.mkdir_p!(ebin)
      link_priv(dir, Path.dirname(ebin))

      paths = List.wrap(config[:elixirc_paths] || ["lib"])

      files =
        paths |> Enum.flat_map(&Path.wildcard(Path.join([dir, &1, "**", "*.ex"]))) |> Enum.sort()

      case Kernel.ParallelCompiler.compile_to_path(files, ebin, return_diagnostics: true) do
        {:ok, modules, %{compile_warnings: w, runtime_warnings: r}} ->
          Code.prepend_path(ebin)
          load_app(app, config, application, deps, modules, ebin)
          apply_config(app, app_config)

          case Application.ensure_all_started(app) do
            {:ok, _} ->
              endpoint = Enum.find(modules, &function_exported?(&1, :__sockets__, 0))
              {:ok, app, endpoint, modules, diagnostics(w ++ r, dir)}

            {:error, reason} ->
              {:error, "The app did not start: " <> start_error(reason), diagnostics(w ++ r, dir)}
          end

        {:error, errors, %{compile_warnings: w, runtime_warnings: r}} ->
          {:error, "The project did not compile.", diagnostics(errors ++ w ++ r, dir)}
      end
    end)
  end

  # config/config.exs (and the file of the env), then config/runtime.exs, as
  # Mix reads them. The studio then changes the endpoint: the front plug
  # calls it (no server of its own), with no code reloader and no watchers.
  defp read_config(app, dir) do
    config_file = Path.join(dir, "config/config.exs")
    runtime_file = Path.join(dir, "config/runtime.exs")

    config =
      if File.regular?(config_file),
        do: Config.Reader.read!(config_file, env: :dev, target: :host),
        else: []

    config =
      if File.regular?(runtime_file),
        do:
          Config.Reader.merge(
            config,
            Config.Reader.read!(runtime_file, env: :dev, target: :host, imports: :disabled)
          ),
        else: config

    Enum.map(config, fn
      {^app, env} -> {app, env |> Enum.map(&endpoint_config/1) |> Enum.map(&repo_config/1)}
      other -> other
    end)
  end

  defp apply_config(app, config) do
    for {key, _} <- Application.get_all_env(app), do: Application.delete_env(app, key)
    Application.put_all_env(config)
  end

  defp endpoint_config({key, value} = pair) when is_atom(key) and is_list(value) do
    if String.ends_with?(Atom.to_string(key), "Endpoint") and Keyword.keyword?(value) do
      url = Keyword.merge(Keyword.get(value, :url, []), path: base_path())

      {key,
       value
       |> Keyword.drop([:live_reload, :watchers, :http, :https])
       |> Keyword.merge(server: false, code_reloader: false, check_origin: false, url: url)}
    else
      pair
    end
  end

  defp endpoint_config(other), do: other

  # In WebAssembly, the SQLite of beam.com has no WAL for the files in the
  # memory of the VM: the close of a database in WAL mode does not end. So
  # a repo of the project uses the journal mode "delete".
  defp repo_config({key, value} = pair) when is_atom(key) and is_list(value) do
    if wasm?() and String.ends_with?(Atom.to_string(key), "Repo") and Keyword.keyword?(value),
      do: {key, Keyword.put(value, :journal_mode, :delete)},
      else: pair
  end

  defp repo_config(other), do: other

  defp wasm?, do: List.starts_with?(:erlang.system_info(:system_architecture), ~c"wasm32")

  defp base_path, do: if(base() == "", do: "/", else: base())

  # The applications of the dependencies that run: not only: :test, not
  # runtime: false, and in the release.
  defp runtime_deps(deps) do
    for dep <- deps,
        {name, opts} = dep_opts(dep),
        opts[:runtime] != false,
        opts[:app] != false,
        opts[:compile] != false,
        only_dev?(opts[:only]),
        :code.lib_dir(name) |> is_list(),
        do: name
  end

  defp dep_opts({name, opts}) when is_list(opts), do: {name, opts}
  defp dep_opts({name, _req}), do: {name, []}
  defp dep_opts({name, _req, opts}), do: {name, opts}
  defp dep_opts(name) when is_atom(name), do: {name, []}

  defp only_dev?(nil), do: true
  defp only_dev?(only), do: :dev in List.wrap(only)

  # Plug.Static and Ecto.Migrator read priv/ in the directory of the app,
  # as with Mix: _build/dev/lib/APP/priv.
  defp link_priv(dir, app_dir) do
    target = Path.join(app_dir, "priv")
    File.rm_rf!(target)

    case File.ln_s(Path.join(dir, "priv"), target) do
      :ok -> :ok
      {:error, _} -> File.cp_r!(Path.join(dir, "priv"), target)
    end
  end

  defp load_app(app, config, application, deps, modules, ebin) do
    :application.unload(app)

    spec =
      [
        description: ~c"#{app}",
        vsn: String.to_charlist(config[:version] || "0.1.0"),
        modules: modules,
        registered: [],
        applications:
          Enum.uniq(
            [:kernel, :stdlib, :elixir, :logger] ++
              (application[:extra_applications] || []) ++ deps
          ),
        env: []
      ] ++ if(application[:mod], do: [mod: application[:mod]], else: [])

    File.write!(
      Path.join(ebin, "#{app}.app"),
      :io_lib.format(~c"~p.~n", [{:application, app, spec}])
    )

    :ok = :application.load({:application, app, spec})
  end

  defp purge(modules) do
    for m <- modules do
      :code.purge(m)
      :code.delete(m)
    end
  end

  defp stop_app(%{app: nil} = state), do: state

  defp stop_app(state) do
    :persistent_term.put({__MODULE__, :endpoint}, nil)
    Application.stop(state.app)
    state
  end

  defp start_error({app, {reason, {mod, :start, _}}}),
    do: "#{app}: #{inspect(mod)}: #{inspect(reason, limit: 20)}"

  defp start_error(reason), do: inspect(reason, limit: 20)

  defp diagnostics(list, dir) do
    for d <- list do
      file = d[:file] && Path.relative_to(to_string(d.file), dir)

      %{
        severity: d[:severity] || :error,
        file: file,
        line: line(d[:position]),
        message: d[:message] |> to_string() |> String.slice(0, 4000)
      }
    end
  end

  defp line({line, _col}), do: line
  defp line(line) when is_integer(line), do: line
  defp line(_), do: nil

  ## State

  defp list_files(dir) do
    dir
    |> walk("")
    |> Enum.sort()
  end

  defp walk(dir, rel) do
    case File.ls(Path.join(dir, rel)) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = if rel == "", do: name, else: Path.join(rel, name)
          full = Path.join(dir, path)

          cond do
            name in @hidden -> []
            String.ends_with?(name, [".db", ".db-shm", ".db-wal"]) -> []
            File.dir?(full) -> walk(dir, path)
            true -> [path]
          end
        end)

      _ ->
        []
    end
  end

  defp set(state, changes) do
    state = Map.merge(state, Map.new(changes))
    Phoenix.PubSub.broadcast(Studio.PubSub, @topic, {:project, info(state)})
    state
  end

  defp info(state) do
    %{
      name: state.dir && Path.basename(state.dir),
      status: state.status,
      message: state.message,
      diagnostics: state.diagnostics,
      log: state.log,
      compiled_ms: state.compiled_ms,
      endpoint: endpoint()
    }
  end
end
