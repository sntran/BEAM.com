defmodule TailwindCheck do
  @moduledoc """
  `tailwind_check.com`: Tailwind CSS with the NIF of tailwind.com.

  At the start, the program builds one stylesheet with Tailwind CSS 4.3.5
  and 4.1.0 (both in the NIF), writes "tailwind_check: ok", and stops.
  With no NIF (no objects in the priv directory of the application
  tailwind), or with an error, it writes the reason and stops with the
  status 1.
  """
  use Application

  def start(_type, _args) do
    case check() do
      :ok ->
        IO.puts("tailwind_check: ok")
        System.halt(0)

      {:error, reason} ->
        IO.puts("tailwind_check: #{reason}")
        System.halt(1)
    end
  end

  defp check do
    dir = Path.join(System.tmp_dir!(), "tailwind_check_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.write!(Path.join(dir, "in.css"), """
      @import "tailwindcss";
      @source inline("flex p-4 text-red-500");
      """)

      if :tailwind.nif(), do: build(dir), else: {:error, "no NIF of tailwind.com"}
    rescue
      e -> {:error, Exception.message(e)}
    after
      File.rm_rf(dir)
    end
  end

  defp build(dir) do
    Enum.reduce_while(["4.3.5", "4.1.0"], :ok, fn vsn, :ok ->
      name = String.to_atom("check_" <> vsn)
      out = Path.join(dir, "#{vsn}.css")

      Application.put_env(:tailwind, name,
        args: ["--input=in.css", "--output=#{out}"],
        cd: dir,
        env: %{"TAILWINDCSS_VERSION" => vsn}
      )

      status = Tailwind.run(name, [])
      css = if File.exists?(out), do: File.read!(out), else: ""

      if status == 0 and css =~ "tailwindcss v#{vsn}" and css =~ ".flex" do
        {:cont, :ok}
      else
        {:halt,
         {:error, "Tailwind CSS #{vsn}: the status #{status}, #{byte_size(css)} bytes of CSS"}}
      end
    end)
  end
end
