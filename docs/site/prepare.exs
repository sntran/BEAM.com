# Copies the Markdown files of the repository into DIR for ExDoc, with the
# links rewritten: a link to another of these files goes to its page, and
# a link to any other file of the repository goes to GitHub.
#
#   beam.com docs/site/prepare.exs -- DIR
[out] = System.argv()
root = Path.expand("../..", __DIR__)
repo = "https://github.com/sntran/BEAM.com"

sources =
  ["README.md", "CONTRIBUTING.md", "SECURITY.md"] ++
    Enum.map(Path.wildcard(Path.join(root, "docs/*.md")), &Path.relative_to(&1, root)) ++
    Enum.map(Path.wildcard(Path.join(root, "docs/history/*.md")), &Path.relative_to(&1, root))

pages = MapSet.new(sources)
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
        MapSet.member?(pages, relative) -> Path.basename(relative) <> anchor
        File.dir?(full) -> "#{repo}/tree/main/#{relative}#{anchor}"
        true -> "#{repo}/blob/main/#{relative}#{anchor}"
      end
  end
end

for source <- sources do
  text =
    root
    |> Path.join(source)
    |> File.read!()
    |> then(&Regex.replace(~r/\]\(([^)\s]+)\)/, &1, fn _, target -> "](#{rewrite.(source, target)})" end))

  File.write!(Path.join(out, Path.basename(source)), text)
end

IO.puts("prepare.exs: #{length(sources)} pages in #{out}")
