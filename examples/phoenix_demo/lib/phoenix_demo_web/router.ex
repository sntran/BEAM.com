defmodule PhoenixDemoWeb.Router do
  use PhoenixDemoWeb, :router

  import PhoenixDemoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :put_cloudflare_request
  end

  # Cloudflare names the data center of a request in its cf-ray header (for
  # example "8f2d3a1b2c3d4e5f-SJC"), and the country of the visitor in
  # cf-ipcountry. The home page shows them.
  defp put_cloudflare_request(conn, _opts) do
    case get_req_header(conn, "cf-ray") do
      [ray | _] ->
        conn
        |> put_session(:cf_colo, ray |> String.split("-") |> List.last())
        |> put_session(:cf_country, conn |> get_req_header("cf-ipcountry") |> List.first())

      [] ->
        conn
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", PhoenixDemoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  # The demo sends no real email. The emails stay in memory (the local
  # adapter of Swoosh), and anybody can read them here.
  scope "/" do
    pipe_through :browser

    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  if Application.compile_env(:phoenix_demo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PhoenixDemoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PhoenixDemoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PhoenixDemoWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PhoenixDemoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PhoenixDemoWeb.UserAuth, :mount_current_scope}] do
      live "/", DemoLive, :home
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
