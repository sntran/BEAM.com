import Config

config :notes, ecto_repos: [Notes.Repo]
config :notes, Notes.Repo, database: "notes.db", pool_size: 1
config :logger, level: :info
