# Makes the notebooks of the Learn section of Livebook (wasm/livebook)
# from the sources of index.exs: the Markdown pages of the repository and
# the notebooks of this directory.
#
#   elixir.com docs/notebooks/build.exs OUT [BEAM_COM]
#
# OUT gets SLUG.livemd for each notebook, covers/, files/, index.exs (the
# notebooks and the groups, with the paths in OUT, for the config of
# Livebook) and docs-map.json (the slug of each notebook to its page on
# the static site). With BEAM_COM, files/ also gets the first 96 KiB of
# that file and the list of its zip, for the notebook of its anatomy.
#
# In a Markdown page:
# - a link to another source goes to its notebook (SLUG.livemd, which
#   livebook.patch opens in the Learn section), and a link to another file
#   of the repository goes to GitHub;
# - a code block of Elixir or Erlang stays text, unless the line before it
#   is "<!-- run -->".
[out | rest] = System.argv()
here = __DIR__
root = Path.expand("../..", here)
repo = "https://github.com/sntran/BEAM.com"
{%{notebooks: notebooks, groups: groups}, _} = Code.eval_file(Path.join(here, "index.exs"))

slugs = Map.new(notebooks, &{Path.expand(&1.source, root), &1.slug})

rewrite = fn source, target ->
  cond do
    String.match?(target, ~r/^([a-z]+:|#|\/)/) ->
      target

    true ->
      [path | anchor] = String.split(target, "#", parts: 2)
      anchor = Enum.map_join(anchor, &("#" <> &1))
      full = Path.expand(path, Path.dirname(Path.join(root, source)))
      relative = Path.relative_to(full, root)

      cond do
        slug = slugs[full] -> slug <> ".livemd" <> anchor
        File.dir?(full) -> "#{repo}/tree/main/#{relative}#{anchor}"
        true -> "#{repo}/blob/main/#{relative}#{anchor}"
      end
  end
end

# The code blocks of a Markdown page: text, unless "<!-- run -->" is on
# the line before.
code_blocks = fn text ->
  text
  |> String.split("\n")
  |> Enum.reduce({[], nil}, fn line, {acc, prev} ->
    cond do
      String.match?(line, ~r/^```(elixir|erlang)\s*$/) and prev == "<!-- run -->" ->
        {[line | tl(acc)], line}

      String.match?(line, ~r/^```(elixir|erlang)\s*$/) ->
        {[line, "", ~s(<!-- livebook:{"force_markdown":true} -->) | acc], line}

      true ->
        {[line | acc], line}
    end
  end)
  |> elem(0)
  |> Enum.reverse()
  |> Enum.join("\n")
end

File.rm_rf!(out)
Enum.each(["covers", "files"], &File.mkdir_p!(Path.join(out, &1)))

index =
  for n <- notebooks do
    source = n.source

    text =
      root
      |> Path.join(source)
      |> File.read!()
      |> then(&Regex.replace(~r/\]\(([^)\s]+)\)/, &1, fn _, t -> "](#{rewrite.(source, t)})" end))
      |> then(&if(String.ends_with?(source, ".md"), do: code_blocks.(&1), else: &1))

    File.write!(Path.join(out, n.slug <> ".livemd"), text)

    if cover = n[:cover] do
      File.cp!(Path.join([here, cover]), Path.join([out, "covers", cover]))
    end

    for f <- n[:files] || [], File.exists?(Path.join([here, "files", f])) do
      File.cp!(Path.join([here, "files", f]), Path.join([out, "files", f]))
    end

    %{
      path: Path.join(out, n.slug <> ".livemd"),
      slug: n.slug,
      group: n[:group],
      files: Enum.map(n[:files] || [], &Path.join([out, "files", &1])),
      details:
        n[:description] &&
          %{description: n.description, cover_path: Path.join([out, "covers", n.cover])}
    }
  end

groups =
  for g <- groups do
    File.cp!(Path.join(here, g.cover), Path.join([out, "covers", g.cover]))

    %{
      title: g.title,
      description: g.description,
      cover_path: Path.join([out, "covers", g.cover]),
      slugs: for(n <- notebooks, n[:group] == g.id, do: n.slug)
    }
  end

File.write!(
  Path.join(out, "index.exs"),
  inspect(%{notebooks: index, groups: groups}, limit: :infinity, printable_limit: :infinity, pretty: true)
)

# The static site (docs/site): README.md is readme.html, a notebook is
# NAME.html.
map =
  Map.new(notebooks, fn n ->
    {n.slug, (n.source |> Path.basename() |> Path.rootname() |> String.downcase()) <> ".html"}
  end)

File.write!(Path.join(out, "docs-map.json"), JSON.encode!(map))

# The anatomy of beam.com: its first 96 KiB, and the entries of its zip
# (name, size, compressed size, offset), as an Erlang term.
case rest do
  [beam_com] ->
    {:ok, file} = File.open(beam_com, [:read, :binary])
    {:ok, head} = :file.pread(file, 0, 98_304)
    File.close(file)
    File.write!(Path.join([out, "files", "beam-com-head.bin"]), head)
    {:ok, zip} = :zip.list_dir(String.to_charlist(beam_com))

    entries =
      for {:zip_file, name, info, _comment, offset, comp_size} <- zip do
        {to_string(name), elem(info, 1), comp_size, offset}
      end

    File.write!(
      Path.join([out, "files", "beam-com-zip.etf"]),
      :erlang.term_to_binary(%{size: File.stat!(beam_com).size, entries: entries}, [:compressed])
    )

  [] ->
    :ok
end

IO.puts("build.exs: #{length(index)} notebooks, #{length(groups)} groups in #{out}")
