# Copies the pages of the documentation into DIR for ExDoc: the Markdown
# files and the notebooks of docs/notebooks/index.exs, in its order. It
# rewrites the links: a link to another page goes to its page, and a link
# to any other file of the repository goes to GitHub. A notebook
# (NAME.livemd) becomes the page NAME.md.
#
# Each page starts with a link to the same page in Livebook, at the root
# of the site (../#/learn/notebooks/SLUG). DIR/extras.exs gives mix.exs
# the pages, their groups and their sources.
#
#   beam.com docs/site/prepare.exs -- DIR
[out] = System.argv()
root = Path.expand("../..", __DIR__)
repo = "https://github.com/sntran/BEAM.com"

{%{notebooks: notebooks, groups: groups}, _} =
  Code.eval_file(Path.join(root, "docs/notebooks/index.exs"))

group_titles = Map.new(groups, &{&1.id, &1.title})

# The page of a source: NAME.md.
page = fn source -> (source |> Path.basename() |> Path.rootname()) <> ".md" end
pages = Map.new(notebooks, &{&1.source, page.(&1.source)})
File.mkdir_p!(out)

rewrite = fn source, target ->
  cond do
    String.match?(target, ~r/^([a-z]+:|#|\/)/) ->
      target

    true ->
      [path | anchor] = String.split(target, "#", parts: 2)
      anchor = Enum.map_join(anchor, &("#" <> &1))
      full = Path.expand(path, Path.join(root, Path.dirname(source)))
      relative = Path.relative_to(full, root)

      cond do
        name = pages[relative] -> name <> anchor
        File.dir?(full) -> "#{repo}/tree/main/#{relative}#{anchor}"
        true -> "#{repo}/blob/main/#{relative}#{anchor}"
      end
  end
end

extras =
  for n <- notebooks do
    source = n.source
    what = if String.ends_with?(source, ".livemd"), do: "Run this notebook", else: "Open this page"

    # An HTML block, not a Markdown link: ExDoc checks the target of a
    # relative Markdown link, and this target is not a page of ExDoc.
    link =
      ~s(<p><a href="../#/learn/notebooks/#{n.slug}">#{what} in Livebook</a>: ) <>
        "Livebook runs in your browser (Chrome or Edge 137 or later).</p>\n"

    text =
      root
      |> Path.join(source)
      |> File.read!()
      |> then(&Regex.replace(~r/\]\(([^)\s]+)\)/, &1, fn _, t -> "](#{rewrite.(source, t)})" end))
      # The link to Livebook goes after the title.
      |> then(&Regex.replace(~r/^(# [^\n]*\n)/m, &1, "\\1\n" <> link, global: false))

    File.write!(Path.join(out, pages[source]), text)

    group =
      cond do
        n[:group] -> group_titles[n.group]
        n.slug == "beam-com" -> nil
        true -> "Notebooks"
      end

    %{page: "pages/" <> pages[source], group: group, source: source}
  end

File.write!(Path.join(out, "extras.exs"), inspect(extras, limit: :infinity, pretty: true))
IO.puts("prepare.exs: #{length(extras)} pages in #{out}")
