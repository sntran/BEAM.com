defmodule Studio.Assets do
  @moduledoc """
  The assets of the app of the studio, with no esbuild and no Tailwind CLI.

  - `/assets/js/app.js` is a small script. It loads the files of
    assets/js as ES modules from `/__studio/js/`, and it starts the
    Tailwind compile in the browser (priv/static/studio/tailwind.js).
  - A module of `/__studio/js/` is a file of assets/ with its imports
    changed, as esbuild resolves them: a package of the release
    (phoenix, phoenix_html, phoenix_live_view), a relative file, the
    colocated hooks, or a package of npm (from jsDelivr). A file with no
    import and no export (a CommonJS or UMD file, such as topbar.js)
    becomes a module with one default export.
  - `/assets/css/app.css` is the last CSS that the browser compiled, or an
    empty file.
  """

  # The ES module files of the packages of the release.
  @packages %{
    "phoenix" => {:phoenix, "static/phoenix.mjs"},
    "phoenix_html" => {:phoenix_html, "static/phoenix_html.js"},
    "phoenix_live_view" => {:phoenix_live_view, "static/phoenix_live_view.esm.js"}
  }

  @max_css 4_000_000

  def packages, do: @packages

  @doc "The script at /assets/js/app.js."
  def bootstrap(base) do
    """
    // The studio loads the JS of the app as ES modules, with no bundle.
    window.process ??= { env: { NODE_ENV: "development" } };
    import(#{Jason.encode!(base <> "/__studio/static/studio/tailwind.js")}).then((m) => m.run(#{Jason.encode!(base)}));
    import(#{Jason.encode!(base <> "/__studio/js/js/app.js")});
    """
  end

  @doc "A file of the package NAME of the release, or nil."
  def package_file(name) do
    with {app, path} <- Map.get(@packages, name),
         dir when is_list(dir) <- :code.priv_dir(app),
         {:ok, text} <- File.read(Path.join(dir, path)) do
      text
    else
      _ -> nil
    end
  end

  @doc """
  The module for PATH of assets/ (for example "js/app.js"), or nil. A path
  with no extension finds PATH.js, then PATH/index.js, as esbuild does.
  """
  def module(dir, path, base) do
    root = Path.join(dir, "assets")

    with true <- safe?(path),
         file when is_binary(file) <- find(root, path),
         {:ok, text} <- File.read(file) do
      rel = Path.relative_to(file, root)
      {rel, transform(text, rel, base)}
    else
      _ -> nil
    end
  end

  defp safe?(path),
    do: path != "" and Path.type(path) == :relative and ".." not in Path.split(path)

  defp find(root, path) do
    Enum.find(
      [path, path <> ".js", path <> ".mjs", Path.join(path, "index.js")],
      &File.regular?(Path.join(root, &1))
    )
    |> case do
      nil -> nil
      found -> Path.join(root, found)
    end
  end

  @import ~r/(\bimport\s*(?:[\w*{}\s,$]+?\s*from\s*)?|\bexport\s*(?:[\w*{}\s,$]+?\s*)?from\s*|\bimport\s*\(\s*)(["'])([^"']+)\2/

  @doc "The imports of TEXT, changed for the browser. REL is the path of TEXT in assets/."
  def transform(text, rel, base) do
    text =
      if Regex.match?(~r/(^|[;\n])\s*(import|export)\b/, text) do
        text
      else
        commonjs(text)
      end

    text =
      Regex.replace(@import, text, fn _, head, q, spec ->
        head <> q <> resolve(spec, rel, base) <> q
      end)

    # The LiveSocket of phx.new is at "/live": under the path of the site.
    Regex.replace(~r/new LiveSocket\(\s*(["'])\//, text, fn _, q ->
      "new LiveSocket(#{Jason.encode!(base)} + #{q}/"
    end)
  end

  defp resolve(spec, rel, base) do
    cond do
      Map.has_key?(@packages, spec) ->
        base <> "/__studio/pkg/" <> spec <> ".js"

      String.starts_with?(spec, "phoenix-colocated/") ->
        base <>
          "/__studio/colocated/" <>
          String.replace_prefix(spec, "phoenix-colocated/", "") <> "/index.js"

      String.starts_with?(spec, ["./", "../"]) ->
        target =
          rel |> Path.dirname() |> Path.join(spec) |> Path.expand("/") |> String.trim_leading("/")

        base <> "/__studio/js/" <> target

      String.starts_with?(spec, ["http://", "https://", "/"]) ->
        spec

      true ->
        "https://cdn.jsdelivr.net/npm/" <> spec <> "/+esm"
    end
  end

  # A file for CommonJS, UMD or a global: it runs with `module`, `exports`
  # and `this` as in Node.js, and its module.exports is the default export.
  defp commonjs(text) do
    """
    const module = { exports: {} }; const exports = module.exports;
    (function (module, exports) {
    #{text}
    }).call(module.exports, module, exports);
    export default module.exports;
    """
  end

  @doc """
  The colocated hooks of APP (LiveView writes them in the build path of
  the project), as one module with the export `hooks`.
  """
  def colocated(build_dir, app) do
    dir = Path.join([build_dir, "phoenix-colocated", app])
    index = Path.join(dir, "index.js")

    if File.regular?(index) do
      File.read!(index)
    else
      "export const hooks = {};\nexport default {};\n"
    end
  end

  @doc """
  The input of the Tailwind compile: assets/css/app.css, and the text of
  the files where the classes are (the @source paths of phx.new).
  """
  def css_source(dir) do
    css = File.read(Path.join(dir, "assets/css/app.css"))

    text =
      for pattern <- [
            "lib/**/*.{ex,heex,eex}",
            "assets/js/**/*.{js,ts,mjs}",
            "assets/css/**/*.css"
          ],
          file <- Path.wildcard(Path.join(dir, pattern)),
          {:ok, t} = File.read(file),
          do: t

    %{css: elem(css, 1) |> to_string(), text: Enum.join(text, "\n")}
  end

  def css_path(dir), do: Path.join(dir, "_build/studio/app.css")

  def put_css(dir, css) when byte_size(css) <= @max_css do
    path = css_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, css)
  end

  def put_css(_dir, _css), do: {:error, :too_large}
end
