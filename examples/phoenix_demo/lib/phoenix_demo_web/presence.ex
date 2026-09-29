defmodule PhoenixDemoWeb.Presence do
  @moduledoc "Tracks the visitors of the home page (see PhoenixDemoWeb.DemoLive)."
  use Phoenix.Presence, otp_app: :phoenix_demo, pubsub_server: PhoenixDemo.PubSub
end
