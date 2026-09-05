defmodule SubzeroSwarmDashboardWeb.SwarmController do
  use SubzeroSwarmDashboardWeb, :controller

  alias SubzeroSwarmDashboard.FleetCatalog

  def select(conn, %{"swarm" => requested}) do
    if requested in FleetCatalog.current() do
      conn
      |> put_session(:selected_swarm, requested)
      |> redirect(to: ~p"/")
    else
      conn
      |> put_flash(:error, "That swarm is not available")
      |> redirect(to: ~p"/")
    end
  end

  def select(conn, _params), do: redirect(conn, to: ~p"/")
end
