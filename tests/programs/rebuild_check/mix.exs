# A Mix project with the alias assets.deploy: Mix makes its release
# (beam_com_mix). The alias writes priv/static/stamp.txt with a new time
# at each build, as phx.digest writes priv/static/cache_manifest.json.
# Run mode must not build it again when no other file changes
# (beam_com:after_build/3). It has no deps, so the build needs no
# network.
defmodule RebuildCheck.MixProject do
  use Mix.Project

  def project do
    [app: :rebuild_check, version: "0.1.0", deps: [], aliases: ["assets.deploy": [&stamp/1]]]
  end

  def application, do: [mod: {RebuildCheck, []}]

  defp stamp(_args) do
    File.mkdir_p!("priv/static")
    File.write!("priv/static/stamp.txt", "#{System.os_time()}\n")
  end
end
