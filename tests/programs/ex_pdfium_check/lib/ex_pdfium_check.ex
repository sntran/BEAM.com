defmodule ExPdfiumCheck do
  @moduledoc """
  `ex_pdfium_check.com`: PDF documents with the NIF of ex_pdfium (PDFium).

  - No argument: each operation once, with a result that the output
    checks, and "ex_pdfium_check: ok" at the end.
  - `bench [RUNS]`: the median time of each operation, in milliseconds.
    RUNS: default 5.
  """

  def main(["bench" | rest]) do
    runs =
      case rest do
        [n] -> String.to_integer(n)
        [] -> 5
      end

    bench(runs)
  end

  def main([]), do: check()

  # A document of PAGES pages, with text, a rectangle and a line on each.
  defp document(pages) do
    {:ok, doc} = ExPdfium.new()

    Enum.reduce(0..(pages - 1), doc, fn i, doc ->
      {:ok, doc} = ExPdfium.add_page(doc, :a4)
      {:ok, doc} = ExPdfium.draw_text(doc, i, {72, 760}, "Page #{i + 1} of BEAM.com", size: 24)

      {:ok, doc} =
        ExPdfium.draw_text(doc, i, {72, 720}, "The quick brown fox jumps over the lazy dog.",
          font: :times_roman
        )

      {:ok, doc} =
        ExPdfium.draw_rectangle(doc, i, %{left: 72, bottom: 500, right: 300, top: 650},
          fill: {200, 30, 30}
        )

      {:ok, doc} = ExPdfium.draw_line(doc, i, {72, 480}, {520, 480}, stroke_width: 2)
      doc
    end)
  end

  defp out(name, value), do: IO.puts("ex_pdfium_check: #{name} #{inspect(value)}")

  defp check do
    out(:version, ExPdfium.pdfium_version())
    {:ok, bytes} = ExPdfium.save_to_bytes(document(3))
    out(:pdf, binary_part(bytes, 0, 5))
    {:ok, doc} = ExPdfium.open(bytes)
    out(:pages, ExPdfium.page_count(doc))
    {:ok, text} = ExPdfium.extract_text(doc, 1)
    out(:text, text |> String.split() |> Enum.take(5))
    out(:search, ExPdfium.search_text(doc, 2, "lazy dog") |> elem(1) |> length())
    {:ok, info} = ExPdfium.page_info(doc, 0)
    out(:page, {round(info.width), round(info.height)})

    {:ok, bitmap} = ExPdfium.render_page(doc, 0, dpi: 72)
    out(:render, {bitmap.width, bitmap.height, byte_size(bitmap.data)})
    # The red rectangle: the pixel at its middle (186, 842 - 575 points).
    i = (267 * bitmap.width + 186) * 4
    out(:pixel, :binary.bin_to_list(binary_part(bitmap.data, i, 3)))

    {:ok, doc} = ExPdfium.rotate_page(doc, 0, 90)
    {:ok, info} = ExPdfium.page_info(doc, 0)
    out(:rotated, {round(info.width), round(info.height)})
    {:ok, two} = ExPdfium.extract_pages(doc, [0, 2])
    out(:extract, ExPdfium.page_count(two))
    {:ok, doc} = ExPdfium.delete_pages(doc, 1)
    out(:deleted, ExPdfium.page_count(doc))
    out(:bad_pdf, ExPdfium.open("%PDF-1.7 not a document"))
    # Work on 8 processes at once: the lock of ex_pdfium and the dirty
    # schedulers.
    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          {:ok, d} = ExPdfium.open(bytes)
          {:ok, b} = ExPdfium.render_page(d, 2, dpi: 50)
          b.width
        end)
      end

    out(:tasks, Task.await_many(tasks, 60_000) |> Enum.uniq())
    IO.puts("ex_pdfium_check: ok")
  end

  defp bench(runs) do
    IO.puts("ex_pdfium_check bench: #{System.schedulers_online()} schedulers, #{runs} runs")
    {:ok, bytes} = ExPdfium.save_to_bytes(document(20))
    {:ok, doc} = ExPdfium.open(bytes)

    [
      {"make 20 pages", fn -> ExPdfium.save_to_bytes(document(20)) end},
      {"open 20 pages", fn -> ExPdfium.open(bytes) end},
      {"render page 150 dpi", fn -> ExPdfium.render_page(doc, 3, dpi: 150) end},
      {"render page 300 dpi", fn -> ExPdfium.render_page(doc, 3, dpi: 300) end},
      {"text of 20 pages", fn -> ExPdfium.extract_text(doc) end}
    ]
    |> Enum.each(fn {name, f} ->
      f.()
      times = for _ <- 1..runs, do: elem(:timer.tc(f), 0) / 1000
      median = Enum.at(Enum.sort(times), div(runs, 2))

      IO.puts(
        String.pad_trailing(name, 26) <> :erlang.float_to_binary(median, decimals: 1) <> " ms"
      )
    end)
  end
end
