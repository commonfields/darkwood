defmodule DarkwoodWeb.Router do
  use DarkwoodWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DarkwoodWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DarkwoodWeb do
    pipe_through :browser

    get "/join", JoinController, :new
    post "/join", JoinController, :create
    delete "/logout", JoinController, :delete

    live_session :joined, on_mount: [{DarkwoodWeb.SessionHook, :require_join}] do
      live "/", IncidentIndexLive
      live "/incidents/:id", IncidentShowLive
    end
  end

  scope "/api/v1", DarkwoodWeb do
    pipe_through :api

    post "/incidents/:id/ingest", IngestController, :create

    # Signal-first ingest: no incident reference required. The detector routes
    # the signal and may open an incident.
    post "/ingest", SignalIngestController, :create
  end

  scope "/", DarkwoodWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", DarkwoodWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:darkwood, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DarkwoodWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
