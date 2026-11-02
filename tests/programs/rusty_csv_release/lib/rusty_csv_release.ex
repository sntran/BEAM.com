defmodule RustyCsvRelease do
  @moduledoc """
  Parses two lines of CSV with the NIF of rusty_csv at the start of the
  release, writes the rows, and stops the VM.
  """
  use Application

  @impl true
  def start(_type, _args) do
    rows = RustyCSV.RFC4180.parse_string("a,b\n1,2\n", skip_headers: false)
    IO.puts("rusty_csv_release: #{inspect(rows)}")
    System.stop(0)
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
