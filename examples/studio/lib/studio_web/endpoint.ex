defmodule StudioWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :studio

  @session_options [
    store: :cookie,
    key: "_studio_key",
    signing_salt: "cH3y1pQx",
    same_site: "Lax",
    path: "/"
  ]

  socket "/__studio/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/__studio/static", from: :studio, gzip: false, only: ~w(studio)

  plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.Session, @session_options
  plug StudioWeb.Router
end
