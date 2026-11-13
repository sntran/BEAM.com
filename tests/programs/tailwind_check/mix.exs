# A check of the NIF files of tailwind.com (scripts/file_nifs.sh) in a
# beam.com with them (tests/run.sh, tests/run.ps1): the git dep of the
# tag of the pin, so Mix makes a release, and the builder puts the
# objects into the priv directory of the application tailwind. At its
# start, the program builds CSS with the NIF, and stops. The tag must be
# the tag of scripts/file_nifs.sh (TAILWIND_TAG).
defmodule TailwindCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :tailwind_check,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:tailwind, github: "sntran/tailwind.com", tag: "v0.3.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {TailwindCheck, []}]
end
