import Config

config :studio, StudioWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: false,
  check_origin: false,
  pubsub_server: Studio.PubSub,
  live_view: [signing_salt: "Qb7sZr2L"],
  render_errors: [formats: [html: StudioWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason
config :logger, :default_formatter, format: "$time [$level] $message\n"
