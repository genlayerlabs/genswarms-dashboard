defmodule SubzeroSwarmDashboardWeb.Router do
  use SubzeroSwarmDashboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SubzeroSwarmDashboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :dashboard_auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SubzeroSwarmDashboardWeb do
    pipe_through :browser

    live_session :dashboard, on_mount: {SubzeroSwarmDashboardWeb.DashHooks, :default} do
      live "/", OverviewLive
      live "/topology", TopologyLive
      live "/sessions", SessionsLive
      live "/sessions/:id", SessionDetailLive
      live "/events", EventsLive
      live "/usage", UsageLive
      live "/logs", LogsLive
    end
  end

  # Read-only basic auth (spec §10). Active only when DASHBOARD_USER/PASS are set.
  defp dashboard_auth(conn, _opts) do
    user = System.get_env("DASHBOARD_USER")
    pass = System.get_env("DASHBOARD_PASS")

    if user && pass && user != "" do
      Plug.BasicAuth.basic_auth(conn, username: user, password: pass)
    else
      conn
    end
  end

  if Application.compile_env(:subzero_swarm_dashboard, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/_dev", metrics: SubzeroSwarmDashboardWeb.Telemetry
    end
  end
end
