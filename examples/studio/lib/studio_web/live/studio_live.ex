defmodule StudioWeb.StudioLive do
  @moduledoc """
  The page of the studio: the files of the project, an editor, the app in
  a frame, and the output of the generator, the compiler and Mix.
  """
  use Phoenix.LiveView

  alias Studio.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Studio.PubSub, Project.topic())
    info = Project.info()

    {:ok,
     socket
     |> assign(info: info, files: Project.files(), open: nil, busy: false, base: Project.base())
     |> assign(name: "hello", task: "", task_log: [], tab: "problems", page_title: "phx.new")
     |> assign(iex_log: [], binding: [], iex_n: 1)}
  end

  @impl true
  def handle_event("new", %{"name" => name}, socket) do
    name = String.trim(name)
    run(socket, fn -> Project.new(name) end) |> assign(name: name) |> noreply()
  end

  def handle_event("open", %{"path" => path}, socket) do
    case Project.read(path) do
      {:ok, text} ->
        socket
        |> assign(open: path)
        |> push_event("open", %{path: path, text: text})
        |> noreply()

      {:error, reason} ->
        socket |> put_flash(:error, "#{path}: #{reason_text(reason)}") |> noreply()
    end
  end

  def handle_event("save", %{"path" => path, "text" => text}, socket) do
    case Project.write(path, text) do
      :ok ->
        run(socket, &Project.build/0) |> noreply()

      {:error, reason} ->
        socket |> put_flash(:error, "#{path}: #{reason_text(reason)}") |> noreply()
    end
  end

  def handle_event("build", _params, socket), do: run(socket, &Project.build/0) |> noreply()

  def handle_event("task", %{"task" => line}, socket) do
    line = String.trim(line)

    run(socket, fn -> {:task, Project.mix(line)} end)
    |> assign(task: line, tab: "mix")
    |> noreply()
  end

  def handle_event("eval", %{"code" => code}, socket) do
    binding = socket.assigns.binding
    n = socket.assigns.iex_n

    socket
    |> run(fn -> {:eval, n, code, Studio.Console.eval(code, binding)} end)
    |> assign(tab: "iex")
    |> noreply()
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(problems log mix iex),
    do: socket |> assign(tab: tab) |> noreply()

  @impl true
  def handle_info({:project, info}, socket) do
    # A new build runs: the frame loads the app again.
    reload? = info.status == :running and socket.assigns.info.status != :running
    socket = assign(socket, info: info)
    if reload?, do: socket |> push_event("reload", %{}) |> noreply(), else: noreply(socket)
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    socket = assign(socket, busy: false, files: Project.files())

    socket =
      case result do
        {:task, {:ok, lines}} ->
          assign(socket, task_log: lines, task: "")

        {:task, {:error, lines}} ->
          assign(socket, task_log: lines)

        {:eval, n, code, {output, binding}} ->
          entry = %{n: n, code: code, output: output}

          assign(socket,
            iex_log: Enum.take([entry | socket.assigns.iex_log], 50),
            binding: binding,
            iex_n: n + 1
          )

        {:error, message} ->
          put_flash(socket, :error, message)

        _ ->
          socket
      end

    socket =
      if socket.assigns.open == nil and socket.assigns.info.status == :running do
        open_first(socket)
      else
        socket
      end

    noreply(socket)
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    socket
    |> assign(busy: false)
    |> put_flash(:error, "The task stopped: #{inspect(reason)}")
    |> noreply()
  end

  defp open_first(socket) do
    path = "lib/#{socket.assigns.info.name}_web/controllers/page_html/home.html.heex"

    if path in socket.assigns.files do
      {:noreply, socket} = handle_event("open", %{"path" => path}, socket)
      socket
    else
      socket
    end
  end

  # A long call (generate, build, Mix) runs in a task, so the page stays live.
  defp run(%{assigns: %{busy: true}} = socket, _fun),
    do: put_flash(socket, :error, "Wait for the last task.")

  defp run(socket, fun) do
    Task.Supervisor.async_nolink(Studio.Tasks, fun)
    assign(socket, busy: true) |> clear_flash()
  end

  defp noreply(socket), do: {:noreply, socket}

  defp reason_text(:too_large), do: "the file is too large for the editor"
  defp reason_text(:binary), do: "the file is not text"
  defp reason_text(:invalid_path), do: "the path is not in the project"
  defp reason_text(reason), do: inspect(reason)

  ## Page

  @impl true
  def render(%{info: %{name: nil}} = assigns) do
    ~H"""
    <main class="welcome">
      <section class="card">
        <p class="eyebrow">Phoenix, in this {host_word(@base)}</p>
        <h1>mix phx.new</h1>
        <p class="lead">
          The generator of Phoenix makes a new project here. The VM compiles it and runs it.
          Change a file, save it, and the app runs again. Nothing to install.
        </p>
        <form phx-submit="new" class="new">
          <label for="name" class="prompt">$ mix phx.new</label>
          <input
            id="name"
            name="name"
            value={@name}
            autocomplete="off"
            spellcheck="false"
            pattern="[a-z][a-z0-9_]*"
            maxlength="40"
            required
          />
          <button type="submit" disabled={@busy}>{if @busy, do: "Working…", else: "Create"}</button>
        </form>
        <p class="hint">Options: --database sqlite3 --no-mailer --no-dashboard --no-gettext</p>
        <.flash flash={@flash} />
        <pre :if={@info.log != [] or @busy} class="log">{Enum.join(@info.log, "\n")}{status_line(@info, @busy)}</pre>
      </section>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="studio">
      <header class="bar">
        <span class="brand">phx.new</span>
        <span class="project">{@info.name}</span>
        <span class={"pill #{@info.status}"}>{status_text(@info)}</span>
        <span class="spacer"></span>
        <form phx-submit="task" class="task">
          <label for="task" class="prompt">$ mix</label>
          <input
            id="task"
            name="task"
            value={@task}
            placeholder="phx.gen.live Blog Post posts title body:text"
            autocomplete="off"
            spellcheck="false"
          />
        </form>
        <button phx-click="build" disabled={@busy}>Restart</button>
        <a class="button" href={"#{@base}/__studio/download"} download>Download</a>
      </header>

      <nav class="files" aria-label="Files">
        <.tree files={@files} open={@open} />
      </nav>

      <section class="editor">
        <div class="editor-bar">
          <span class="path">{@open || "No file"}</span>
          <button id="save" disabled={@open == nil or @busy} data-save>Save and run</button>
        </div>
        <div id="editor" phx-hook="Editor" phx-update="ignore" class="cm"></div>
      </section>

      <section class="preview">
        <div id="preview" phx-hook="Preview" phx-update="ignore" data-base={@base}>
          <div class="preview-bar">
            <input class="address" value="/" aria-label="Path of the app" spellcheck="false" />
            <a class="open" target="_blank" href={@base <> "/"}>Open</a>
          </div>
          <%!-- With no app, the frame stays empty until the first "reload". --%>
          <iframe title="The app" src={if @info.endpoint, do: @base <> "/", else: "about:blank"}></iframe>
        </div>
      </section>

      <section class="panel">
        <div class="tabs" role="tablist">
          <button
            :for={
              {id, label} <- [
                {"problems", "Problems (#{length(@info.diagnostics)})"},
                {"iex", "IEx"},
                {"log", "Generator"},
                {"mix", "Mix"}
              ]
            }
            role="tab"
            aria-selected={to_string(@tab == id)}
            phx-click="tab"
            phx-value-tab={id}
          >{label}</button>
        </div>
        <.flash flash={@flash} />
        <div :if={@tab == "problems"} class="problems">
          <p :if={@info.message} class="message">{@info.message}</p>
          <p :if={@info.diagnostics == [] and @info.message == nil} class="quiet">
            No problems. Built in {@info.compiled_ms} ms.
          </p>
          <button
            :for={d <- @info.diagnostics}
            class={"diag #{d.severity}"}
            phx-click={d.file && "open"}
            phx-value-path={d.file}
            data-line={d.line}
          >
            <span class="where">{d.file}{if d.line, do: ":#{d.line}"}</span>
            <span class="what">{d.message}</span>
          </button>
        </div>
        <div :if={@tab == "iex"} class="iex">
          <pre class="log" id="iex-log"><%= for e <- Enum.reverse(@iex_log) do %><span class="in">iex({e.n})&gt; {e.code}</span>
    {e.output}
    <% end %></pre>
          <form phx-submit="eval" class="iex-line">
            <label for="code" class="prompt">iex({@iex_n})&gt;</label>
            <input
              id="code"
              name="code"
              value=""
              autocomplete="off"
              spellcheck="false"
              placeholder="Hello.Repo.all(Hello.Blog.Post)"
            />
          </form>
        </div>
        <pre :if={@tab == "log"} class="log">{Enum.join(@info.log, "\n")}</pre>
        <pre :if={@tab == "mix"} class="log">{if @task_log == [], do: "Run a generator of Phoenix or Ecto in the field $ mix, then add its routes.", else: Enum.join(@task_log, "\n")}</pre>
      </section>
    </div>
    """
  end

  attr :files, :list, required: true
  attr :open, :string

  defp tree(assigns) do
    assigns = assign(assigns, groups: group(assigns.files))

    ~H"""
    <ul class="tree">
      <li :for={{dir, files} <- @groups}>
        <details open={
          dir == "" or String.starts_with?(@open || "", dir <> "/") or String.starts_with?(dir, "lib")
        }>
          <summary :if={dir != ""}>{dir}/</summary>
          <ul>
            <li :for={f <- files}>
              <button class={"file #{if f == @open, do: "on"}"} phx-click="open" phx-value-path={f}>{Path.basename(
                f
              )}</button>
            </li>
          </ul>
        </details>
      </li>
    </ul>
    """
  end

  defp group(files) do
    files
    |> Enum.group_by(fn f -> if Path.dirname(f) == ".", do: "", else: Path.dirname(f) end)
    |> Enum.sort_by(fn {dir, _} -> {dir != "", dir} end)
  end

  attr :flash, :map, required: true

  defp flash(assigns) do
    ~H"""
    <p :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash" role="alert">{msg}</p>
    """
  end

  defp status_text(%{status: :running, compiled_ms: ms}), do: "running · #{ms} ms"
  defp status_text(%{status: :compiling}), do: "compiling…"
  defp status_text(%{status: :generating}), do: "generating…"
  defp status_text(%{status: :error}), do: "error"
  defp status_text(%{status: status}), do: to_string(status)

  defp status_line(%{status: :compiling}, _), do: "\n* compiling the project…"
  defp status_line(%{status: :generating}, _), do: "\n* running the generator…"
  defp status_line(_, true), do: "\n* working…"
  defp status_line(_, _), do: ""

  defp host_word(_base), do: "VM"
end
