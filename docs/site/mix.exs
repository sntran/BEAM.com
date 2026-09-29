# The documentation site of BEAM.com (GitHub Pages): the README and the
# pages of docs/, as ExDoc makes the sites of hexdocs.pm. docs/site.sh
# builds it with the tools of beam.com.
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
        extras: Enum.map(extras(), &"pages/#{&1}.md"),
        groups_for_extras: [
          Guides: ~r"pages/(PROGRAMS|ELIXIR|WORKERS|NOTEBOOKS|LIBRARIES|SANDBOX)\.md",
          Reference: ~r"pages/(PLATFORMS|INTERNALS|JIT|BENCHMARKS|UPSTREAM)\.md",
          Project: ~r"pages/(BUILDING|TESTING|ROADMAP|CONTRIBUTING|SECURITY)\.md",
          History: ~r"pages/(WASM-LOG|JIT-DESIGN)\.md"
        ],
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
    name = Path.basename(path)

    dir =
      cond do
        name in ~w(README.md CONTRIBUTING.md SECURITY.md) -> ""
        name in ~w(WASM-LOG.md JIT-DESIGN.md) -> "docs/history/"
        true -> "docs/"
      end

    "https://github.com/sntran/BEAM.com/blob/main/#{dir}#{name}#L#{line}"
  end

  defp extras do
    ~w(README PROGRAMS ELIXIR WORKERS NOTEBOOKS LIBRARIES SANDBOX PLATFORMS INTERNALS JIT
       BENCHMARKS UPSTREAM BUILDING TESTING ROADMAP CONTRIBUTING SECURITY WASM-LOG JIT-DESIGN)
  end
end
