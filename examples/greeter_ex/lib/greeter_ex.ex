defmodule GreeterEx do
  @moduledoc "Prints a greeting from the configuration, and JSON with jason."

  def run do
    greeting = Application.fetch_env!(:greeter_ex, :greeting)
    for n <- 1..Application.get_env(:greeter_ex, :times, 1) do
      IO.puts("greeter_ex: #{greeting} (#{n})")
    end

    json = Jason.encode!(%{elixir: System.version(), otp: System.otp_release()})
    IO.puts("greeter_ex: json #{json}")
    %{"elixir" => version} = Jason.decode!(json)
    IO.puts("greeter_ex: decoded #{version}")
    System.stop(0)
  end
end
