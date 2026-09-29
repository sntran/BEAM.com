defmodule Studio.Front do
  @moduledoc """
  The plug of the server of the VM. It sends a request:

  - to the studio (`StudioWeb.Endpoint`) for a path under /__studio;
  - to the asset pipeline (`Studio.Assets`) for /assets/js/app.js,
    /assets/css/app.css and the modules of /__studio/js, /__studio/pkg and
    /__studio/colocated;
  - else to the endpoint of the app of the project. When no app runs,
    the page says why and links to the studio.

  The host (a path tenant of Workers, or the service worker of the page)
  removes the path of the site before the VM gets the request. So the
  plug puts that path back in `script_name`, and Phoenix makes links
  with it.
  """
  @behaviour Plug
  import Plug.Conn

  alias Studio.{Assets, Project}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    base = Project.base()
    conn = %{conn | script_name: Path.split(base) -- ["/"]}
    route(conn, conn.path_info, base)
  end

  defp route(conn, ["__studio", "pkg", file], _base) do
    name = String.replace_suffix(file, ".js", "")

    case Assets.package_file(name) do
      nil -> not_found(conn)
      text -> js(conn, text, "public, max-age=3600")
    end
  end

  defp route(conn, ["__studio", "js" | path], base) do
    with dir when is_binary(dir) <- Project.dir(),
         {_rel, text} <- Assets.module(dir, Path.join(path), base) do
      js(conn, text, "no-cache")
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["__studio", "colocated", app, "index.js"], _base) do
    case Project.dir() do
      nil -> not_found(conn)
      dir -> js(conn, Assets.colocated(Path.join(dir, "_build/dev"), app), "no-cache")
    end
  end

  defp route(conn, ["__studio", "css"], _base) do
    case {conn.method, Project.dir()} do
      {_, nil} ->
        not_found(conn)

      {"GET", dir} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, Jason.encode!(Assets.css_source(dir)))

      {"PUT", dir} ->
        case read_body(conn, length: 4_000_000) do
          {:ok, css, conn} ->
            Assets.put_css(dir, css)
            send_resp(conn, 204, "")

          {_, _, conn} ->
            send_resp(conn, 413, "")
        end

      _ ->
        send_resp(conn, 405, "")
    end
  end

  defp route(conn, ["__studio" | _], _base),
    do: StudioWeb.Endpoint.call(conn, StudioWeb.Endpoint.init([]))

  defp route(conn, ["assets", "js", "app.js"], base) do
    if Project.endpoint(), do: js(conn, Assets.bootstrap(base), "no-cache"), else: app(conn, base)
  end

  defp route(conn, ["assets", "css", "app.css"], base) do
    case Project.dir() && File.read(Assets.css_path(Project.dir())) do
      {:ok, css} ->
        conn
        |> put_resp_content_type("text/css")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, css)

      _ ->
        if Project.endpoint(),
          do: conn |> put_resp_content_type("text/css") |> send_resp(200, ""),
          else: app(conn, base)
    end
  end

  defp route(conn, _path, base), do: app(conn, base)

  defp app(conn, base) do
    is_frame = get_req_header(conn, "sec-fetch-dest") == ["iframe"]

    case Project.endpoint() do
      # The root goes to the studio, but not in the frame of the studio.
      nil when conn.path_info == [] and not is_frame ->
        conn |> put_resp_header("location", base <> "/__studio/") |> send_resp(302, "")

      nil ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("retry-after", "2")
        |> send_resp(503, idle_page(base))

      endpoint ->
        endpoint.call(conn, endpoint.init([]))
    end
  end

  defp js(conn, text, cache) do
    conn
    |> put_resp_content_type("text/javascript")
    |> put_resp_header("cache-control", cache)
    |> send_resp(200, text)
  end

  defp not_found(conn),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")

  defp idle_page(base) do
    """
    <!doctype html><meta charset="utf-8"><title>No app</title>
    <meta http-equiv="refresh" content="2">
    <style>body{font:16px/1.5 system-ui,sans-serif;margin:3rem;color:#44403c}</style>
    <p>The app does not run now. It compiles, or it has an error.</p>
    <p><a href="#{base}/__studio/" target="_top">Open the studio</a></p>
    """
  end
end
