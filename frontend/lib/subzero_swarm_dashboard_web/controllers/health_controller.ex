defmodule SubzeroSwarmDashboardWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness probe for container orchestration. Reports only that
  the dashboard web process is up — it does NOT proxy the swarm's health (that is
  shown in the UI as the connection/co-location banners).
  """
  use SubzeroSwarmDashboardWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "subzero_swarm_dashboard"})
  end
end
