defmodule SubzeroSwarmDashboardWeb.Router do
  use SubzeroSwarmDashboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_privacy_assign
    plug :put_root_layout, html: {SubzeroSwarmDashboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :dashboard_auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Unauthenticated liveness probe (for Docker/compose healthchecks).
  scope "/", SubzeroSwarmDashboardWeb do
    pipe_through :api
    get "/healthz", HealthController, :show
  end

  scope "/", SubzeroSwarmDashboardWeb do
    pipe_through :browser

    post "/privacy/toggle", PrivacyController, :toggle
    post "/swarm/select", SwarmController, :select

    live_session :dashboard, on_mount: {SubzeroSwarmDashboardWeb.DashHooks, :default} do
      live "/", OverviewLive
      live "/topology", TopologyLive
      live "/sessions", SessionsLive
      live "/sessions/:id", SessionDetailLive
      live "/events", EventsLive
      live "/usage", UsageLive
      live "/extensions/:id", ExtensionPageLive
      live "/logs", LogsLive
      live "/config", ConfigLive
    end
  end

  # Both absent or both empty delegates authentication to the ingress (Compose
  # passes empty strings). Partial configuration must not accept an empty credential.
  defp dashboard_auth(conn, _opts) do
    user = System.get_env("DASHBOARD_USER")
    pass = System.get_env("DASHBOARD_PASS")

    cond do
      (is_nil(user) and is_nil(pass)) or (user == "" and pass == "") ->
        conn

      is_binary(user) and is_binary(pass) and String.trim(user) != "" and String.trim(pass) != "" ->
        Plug.BasicAuth.basic_auth(conn, username: user, password: pass)

      true ->
        conn
        |> send_resp(503, "Dashboard authentication is not configured correctly")
        |> halt()
    end
  end

  defp put_privacy_assign(conn, _opts) do
    assign(conn, :privacy, privacy_enabled?(get_session(conn, :privacy)))
  end

  defp privacy_enabled?(true), do: true
  defp privacy_enabled?("true"), do: true
  defp privacy_enabled?(_), do: false

  if Application.compile_env(:subzero_swarm_dashboard, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/_dev", metrics: SubzeroSwarmDashboardWeb.Telemetry
    end
  end
end
