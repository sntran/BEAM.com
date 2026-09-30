import Config

config :studio, StudioWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: false,
  check_origin: false,
  pubsub_server: Studio.PubSub,
  live_view: [signing_salt: "Qb7sZr2L"],
  render_errors: [formats: [html: StudioWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

# No default poller: with "-Mea min" (Workers), :erlang.memory/0 is not
# supported, and the poller logs an error.
config :telemetry_poller, :default, false
config :logger, :default_formatter, format: "$time [$level] $message\n"
