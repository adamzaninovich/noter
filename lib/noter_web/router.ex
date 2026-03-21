defmodule NoterWeb.Router do
  use NoterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NoterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NoterWeb do
    pipe_through :browser

    live "/", CampaignLive.Index
    live "/campaigns/:campaign_slug", CampaignLive.Show
    live "/campaigns/:campaign_slug/sessions/new", SessionLive.New
    live "/campaigns/:campaign_slug/sessions/:session_slug", SessionLive.Show

    get "/sessions/:session_id/audio/merged", AudioController, :merged
    get "/sessions/:session_id/audio/peaks", AudioController, :peaks
  end

  # Other scopes may use custom stacks.
  # scope "/api", NoterWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:noter, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NoterWeb.Telemetry
    end
  end
end
