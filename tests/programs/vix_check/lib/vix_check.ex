defmodule VixCheck do
  @moduledoc """
  `vix_check.com`: image operations with the NIF of vix.

  - No argument: each operation once, with a result that the output
    checks, and "vix_check: ok" at the end. The formats: JPEG, PNG and
    WebP, and the parts of VIX_PARTS when the build has them (AVIF, GIF
    save, ICC transforms, SVG load; else "not in this build").
  - `bench [RUNS]`: the median time of each operation, in milliseconds,
    on an image of 4000x3000 (12 megapixels). RUNS: default 5.
  """
  alias Vix.Vips.{Image, Operation}

  # An SVG of 160x120: a rectangle and a circle with half alpha.
  @svg """
  <svg xmlns="http://www.w3.org/2000/svg" width="160" height="120">
    <rect x="10" y="10" width="140" height="100" fill="#c03020"/>
    <circle cx="80" cy="60" r="40" fill="#2040c0" fill-opacity="0.5"/>
  </svg>
  """

  # Only text, on no background: its alpha is 0 when no font drew it.
  @svg_text """
  <svg xmlns="http://www.w3.org/2000/svg" width="160" height="40">
    <text x="4" y="30" font-family="sans-serif" font-size="24">vix svg</text>
  </svg>
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

  # An RGB image of noise (the same each run): JPEG and WebP do work on
  # it, as on a photo.
  defp noise(w, h) do
    bands =
      for seed <- [1, 2, 3] do
        {:ok, n} = Operation.gaussnoise(w, h, mean: 128.0, sigma: 40.0, seed: seed)
        {:ok, b} = Operation.cast(n, :VIPS_FORMAT_UCHAR)
        b
      end

    {:ok, img} = Operation.bandjoin(bands)
    {:ok, img} = Image.copy_memory(img)
    img
  end

  defp avg(img) do
    {:ok, a} = Operation.avg(img)
    Float.round(a, 1)
  end

  defp check do
    IO.puts("vix_check: libvips #{Vix.Vips.version()}")
    img = noise(640, 480)
    IO.puts("vix_check: noise #{Image.width(img)}x#{Image.height(img)}x#{Image.bands(img)}")
    {:ok, jpg} = Image.write_to_buffer(img, ".jpg[Q=90]")
    {:ok, back} = Image.new_from_buffer(jpg)
    IO.puts("vix_check: jpeg #{Image.width(back)}x#{Image.height(back)} average #{avg(back)}")
    {:ok, small} = Operation.resize(back, 0.25)
    IO.puts("vix_check: resize #{Image.width(small)}x#{Image.height(small)}")
    {:ok, png} = Image.write_to_buffer(small, ".png")
    {:ok, png_back} = Image.new_from_buffer(png)
    IO.puts("vix_check: png #{Image.width(png_back)}x#{Image.height(png_back)}")
    {:ok, webp} = Image.write_to_buffer(small, ".webp")
    {:ok, webp_back} = Image.new_from_buffer(webp)
    IO.puts("vix_check: webp #{Image.width(webp_back)}x#{Image.height(webp_back)}")
    # The parts of VIX_PARTS: AVIF (libheif with aom), GIF save (cgif),
    # and ICC transforms (lcms2) with the built-in profiles of libvips.
    part("avif", fn ->
      {:ok, avif} = Image.write_to_buffer(small, ".avif[Q=60]")
      {:ok, back} = Image.new_from_buffer(avif)
      "#{Image.width(back)}x#{Image.height(back)}"
    end)

    part("gif", fn ->
      {:ok, gif} = Image.write_to_buffer(small, ".gif")
      {:ok, back} = Image.new_from_buffer(gif)
      "#{Image.width(back)}x#{Image.height(back)}"
    end)

    part("icc", fn ->
      {:ok, cmyk} = icc(small, "cmyk")
      {:ok, srgb} = icc(cmyk, "srgb")
      "#{Image.bands(cmyk)} bands, then #{Image.bands(srgb)} bands"
    end)

    # SVG load with resvg: the SVG, its SVGZ, an SVG file, an SVG that
    # links a PNG file (the loader must not read it), and text with the
    # fonts of the system ("no text" on a system with no fonts).
    part("svg", fn -> svg(png) end)

    {:ok, thumb} = Operation.thumbnail_buffer(jpg, 100)
    IO.puts("vix_check: thumbnail #{Image.width(thumb)}x#{Image.height(thumb)}")
    {:ok, black} = Operation.black(64, 64)
    {:ok, gray} = Operation.linear(black, [1.0], [128.0])
    IO.puts("vix_check: average #{avg(gray)}")
    IO.puts("vix_check: ok")
  end

  defp svg(png) do
    base = Path.join(System.tmp_dir!(), "vix_check_#{System.unique_integer([:positive])}")
    File.write!(base <> ".svg", @svg)
    File.write!(base <> ".png", png)

    try do
      {:ok, svg} = Image.new_from_buffer(@svg)
      {:ok, svgz} = Image.new_from_buffer(:zlib.gzip(@svg))
      {:ok, file} = Image.new_from_file(base <> ".svg")

      link =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30">) <>
          ~s(<image href="#{base}.png" width="40" height="30"/></svg>)

      {:ok, linked} = Image.new_from_buffer(link)
      linked = if alpha(linked) > 0, do: "linked file read", else: "linked file refused"
      {:ok, text} = Image.new_from_buffer(@svg_text)
      drawn = if alpha(text) > 0, do: "text", else: "no text"

      "#{Image.width(svg)}x#{Image.height(svg)} #{Image.bands(svg)} bands, " <>
        "svgz #{Image.width(svgz)}x#{Image.height(svgz)}, " <>
        "file #{Image.width(file)}x#{Image.height(file)}, #{linked}, #{drawn}"
    after
      File.rm(base <> ".svg")
      File.rm(base <> ".png")
    end
  end

  defp alpha(img) do
    {:ok, a} = Operation.extract_band(img, 3)
    avg(a)
  end

  # A part of VIX_PARTS: its line, or "not in this build" when the libvips
  # of the build does not have it.
  defp part(name, fun) do
    IO.puts("vix_check: #{name} #{fun.()}")
  rescue
    _ -> IO.puts("vix_check: #{name} not in this build")
  end

  # vix makes the functions of Operation from the operations of its
  # libvips: icc_transform exists only with lcms2.
  defp icc(img, profile), do: apply(Operation, :icc_transform, [img, profile])

  defp bench(runs) do
    # No cache of operations: else a run after the first gets the result
    # of the first.
    :ok = Vix.Vips.cache_set_max(0)

    IO.puts(
      "vix_check bench: libvips #{Vix.Vips.version()}, #{System.schedulers_online()} schedulers, #{runs} runs"
    )

    img = noise(4000, 3000)
    {:ok, jpg} = Image.write_to_buffer(img, ".jpg[Q=80]")
    {:ok, mp1} = Operation.resize(img, 0.288)
    {:ok, mp1} = Image.copy_memory(mp1)

    [
      {"jpeg encode 12 MP", fn -> {:ok, _} = Image.write_to_buffer(img, ".jpg[Q=80]") end},
      {"jpeg decode 12 MP",
       fn ->
         {:ok, i} = Image.new_from_buffer(jpg)
         avg(i)
       end},
      {"thumbnail 12 MP to 400",
       fn ->
         {:ok, t} = Operation.thumbnail_buffer(jpg, 400)
         avg(t)
       end},
      {"resize 12 MP by 0.5",
       fn ->
         {:ok, r} = Operation.resize(img, 0.5)
         avg(r)
       end},
      {"gaussblur 12 MP sigma 5",
       fn ->
         {:ok, b} = Operation.gaussblur(img, 5.0)
         avg(b)
       end},
      {"webp encode 1 MP", fn -> {:ok, _} = Image.write_to_buffer(mp1, ".webp[Q=80]") end},
      {"png encode 1 MP", fn -> {:ok, _} = Image.write_to_buffer(mp1, ".png") end},
      {"avif encode 1 MP", fn -> {:ok, _} = Image.write_to_buffer(mp1, ".avif[Q=60]") end},
      {"icc transform 1 MP",
       fn ->
         {:ok, c} = icc(mp1, "cmyk")
         avg(c)
       end}
    ]
    # Only the operations of the parts of this build.
    |> Enum.filter(fn {_, f} ->
      try do
        f.()
        true
      rescue
        _ -> false
      end
    end)
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
