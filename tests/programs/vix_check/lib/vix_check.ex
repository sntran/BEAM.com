defmodule VixCheck do
  @moduledoc """
  `vix_check.com`: image operations with the NIF of vix.

  - No argument: each operation once, with a result that the output
    checks, and "vix_check: ok" at the end.
  - `bench [RUNS]`: the median time of each operation, in milliseconds,
    on an image of 4000x3000 (12 megapixels). RUNS: default 5.
  """
  alias Vix.Vips.{Image, Operation}

  def main(["bench" | rest]) do
    runs = case rest do [n] -> String.to_integer(n); [] -> 5 end
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
    {:ok, thumb} = Operation.thumbnail_buffer(jpg, 100)
    IO.puts("vix_check: thumbnail #{Image.width(thumb)}x#{Image.height(thumb)}")
    {:ok, black} = Operation.black(64, 64)
    {:ok, gray} = Operation.linear(black, [1.0], [128.0])
    IO.puts("vix_check: average #{avg(gray)}")
    IO.puts("vix_check: ok")
  end

  defp bench(runs) do
    # No cache of operations: else a run after the first gets the result
    # of the first.
    :ok = Vix.Vips.cache_set_max(0)
    IO.puts("vix_check bench: libvips #{Vix.Vips.version()}, #{System.schedulers_online()} schedulers, #{runs} runs")
    img = noise(4000, 3000)
    {:ok, jpg} = Image.write_to_buffer(img, ".jpg[Q=80]")
    {:ok, mp1} = Operation.resize(img, 0.288)
    {:ok, mp1} = Image.copy_memory(mp1)

    [
      {"jpeg encode 12 MP", fn -> {:ok, _} = Image.write_to_buffer(img, ".jpg[Q=80]") end},
      {"jpeg decode 12 MP", fn -> {:ok, i} = Image.new_from_buffer(jpg); avg(i) end},
      {"thumbnail 12 MP to 400", fn -> {:ok, t} = Operation.thumbnail_buffer(jpg, 400); avg(t) end},
      {"resize 12 MP by 0.5", fn -> {:ok, r} = Operation.resize(img, 0.5); avg(r) end},
      {"gaussblur 12 MP sigma 5", fn -> {:ok, b} = Operation.gaussblur(img, 5.0); avg(b) end},
      {"webp encode 1 MP", fn -> {:ok, _} = Image.write_to_buffer(mp1, ".webp[Q=80]") end},
      {"png encode 1 MP", fn -> {:ok, _} = Image.write_to_buffer(mp1, ".png") end}
    ]
    |> Enum.each(fn {name, f} ->
      f.()
      times = for _ <- 1..runs, do: elem(:timer.tc(f), 0) / 1000
      median = Enum.at(Enum.sort(times), div(runs, 2))
      IO.puts(String.pad_trailing(name, 26) <> :erlang.float_to_binary(median, decimals: 1) <> " ms")
    end)
  end
end
