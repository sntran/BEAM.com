# A one-file Elixir program for "beam.com INPUT -o OUTPUT": main/1 gets the
# arguments as binaries (as System.argv/0). "raise" raises an exception,
# which beam.com prints in the format of Elixir (exit status 127).
defmodule ElixirCheck do
  def main(["raise"]), do: raise("boom")

  def main(args) do
    IO.puts("elixir: #{System.version()} on OTP #{System.otp_release()}")
    IO.puts("args: #{inspect(args)}")
    IO.puts("sum: #{Enum.sum(1..100)}")
    IO.puts("upcase: #{String.upcase("beam.com")}")
  end
end
