defmodule RustyCsvCheck do
  @moduledoc """
  `rusty_csv_check.com`: CSV with the NIF of rusty_csv (Rust).

  - No argument: each operation once, with a result that the output
    checks, and "rusty_csv_check: ok" at the end.
  - `bench [RUNS]`: the median time of each operation, in milliseconds,
    for RustyCSV and NimbleCSV, on 100,000 rows (10 MB). RUNS: default 5.
  """
  alias RustyCSV.RFC4180, as: CSV
  alias NimbleCSV.RFC4180, as: Nimble

  def main(["bench" | rest]) do
    runs =
      case rest do
        [n] -> String.to_integer(n)
        [] -> 5
      end

    bench(runs)
  end

  def main([]), do: check()

  # Rows with numbers, text, quotes, separators and line ends in fields.
  defp rows(n) do
    for i <- 1..n do
      [
        Integer.to_string(i),
        "name #{i}",
        Float.to_string(i * 1.25),
        "a \"quoted\" word, #{rem(i, 97)}",
        "line\r\nbreak #{rem(i, 13)}",
        String.duplicate("x", rem(i, 40)),
        "é✓ #{i}",
        ""
      ]
    end
  end

  defp check do
    small = "name,age\r\nada,36\r\n\"bob, jr\",\"4\"\"2\"\r\n\"multi\nline\",x\r\n"
    out(:parse, CSV.parse_string(small))
    out(:headers, CSV.parse_string(small, headers: true))
    out(:no_skip, CSV.parse_string("a,b\n1,2\n", skip_headers: false))
    out(:dump, IO.iodata_to_binary(CSV.dump_to_iodata([["a", "b,c"], ["d\"e", "f\ng"]])))
    out(:strict, error(fn -> CSV.parse_string("a,b\n\"x,y\n", skip_headers: false) end))

    data = rows(20_000)
    csv = IO.iodata_to_binary(CSV.dump_to_iodata(data))
    out(:same_dump, csv == IO.iodata_to_binary(Nimble.dump_to_iodata(data)))
    out(:bytes, byte_size(csv))
    out(:simd, CSV.parse_string(csv, skip_headers: false) == data)
    out(:parallel, CSV.parse_string(csv, skip_headers: false, strategy: :parallel) == data)
    out(:nimble, Nimble.parse_string(csv, skip_headers: false) == data)

    # parse_stream with chunks that cut rows and characters.
    chunks = for <<c::binary-size(4093) <- csv>>, do: c
    rest = binary_part(csv, 4093 * length(chunks), rem(byte_size(csv), 4093))
    streamed = Enum.to_list(CSV.parse_stream(chunks ++ [rest], skip_headers: false))
    out(:stream, streamed == data)

    out(:parallel_dump, IO.iodata_to_binary(CSV.dump_to_iodata(data, strategy: :parallel)) == csv)
    # Parse on 8 processes at once: the dirty schedulers and the threads of
    # rayon.
    tasks = for _ <- 1..8, do: Task.async(fn -> CSV.parse_string(csv, strategy: :parallel) end)
    out(:tasks, Enum.all?(Task.await_many(tasks, 60_000), &(length(&1) == 19_999)))
    IO.puts("rusty_csv_check: ok")
  end

  # The value of f, or the name of the exception that it raises.
  defp error(f) do
    f.()
  rescue
    e -> e.__struct__
  end

  defp out(name, value), do: IO.puts("rusty_csv_check: #{name} #{inspect(value)}")

  defp bench(runs) do
    IO.puts("rusty_csv_check bench: #{System.schedulers_online()} schedulers, #{runs} runs")
    data = rows(100_000)
    csv = IO.iodata_to_binary(CSV.dump_to_iodata(data))
    IO.puts("rusty_csv_check bench: #{byte_size(csv)} bytes")

    [
      {"parse RustyCSV", fn -> CSV.parse_string(csv) end},
      {"parse RustyCSV parallel", fn -> CSV.parse_string(csv, strategy: :parallel) end},
      {"parse NimbleCSV", fn -> Nimble.parse_string(csv) end},
      {"dump RustyCSV", fn -> IO.iodata_length(CSV.dump_to_iodata(data)) end},
      {"dump NimbleCSV", fn -> IO.iodata_length(Nimble.dump_to_iodata(data)) end}
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
