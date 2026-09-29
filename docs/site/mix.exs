# The static documentation of BEAM.com (GitHub Pages, at docs/): the
# README, the pages of docs/ and the notebooks, as ExDoc makes the sites
# of hexdocs.pm. docs/site.sh builds it with the tools of beam.com.
defmodule BeamComDocs.MixProject do
  use Mix.Project

  @version (fn ->
              {:ok, [{:application, :beam_com, props}]} =
                :file.consult(Path.expand("../../apps/beam_com/src/beam_com.app.src", __DIR__))

              to_string(props[:vsn])
            end).()

  def project do
    [
      app: :beam_com_docs,
      version: @version,
      elixir: "~> 1.18",
      deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}],
      name: "BEAM.com",
      source_url: "https://github.com/sntran/BEAM.com",
      homepage_url: "https://github.com/sntran/BEAM.com",
      docs: [
        main: "readme",
        extras: Enum.map(extras(), & &1.page),
        groups_for_extras:
          extras()
          |> Enum.filter(& &1.group)
          |> Enum.chunk_by(& &1.group)
          |> Enum.map(fn pages -> {hd(pages).group, Enum.map(pages, & &1.page)} end),
        # "View source" of a page: its file in the repository.
        source_url_pattern: &source_url/2,
        # The pages name functions of other projects in code spans.
        skip_code_autolink_to: ["Mix.Utils.detect_user_id!/0"],
        api_reference: false,
        formatters: ["html"],
        output: "doc"
      ]
    ]
  end

  defp source_url(path, line) do
    %{source: source} = Enum.find(extras(), &(Path.basename(&1.page) == Path.basename(path)))
    "https://github.com/sntran/BEAM.com/blob/main/#{source}#L#{line}"
  end

  # The pages, their groups and their sources, in the order of
  # docs/notebooks/index.exs (prepare.exs writes pages/extras.exs).
  defp extras do
    elem(Code.eval_file(Path.expand("pages/extras.exs", __DIR__)), 0)
  end
end
