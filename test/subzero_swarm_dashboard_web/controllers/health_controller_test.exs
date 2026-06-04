defmodule SubzeroSwarmDashboardWeb.HealthControllerTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: true

  test "GET /healthz is unauthenticated and reports ok", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok", "service" => "subzero_swarm_dashboard"}
  end
end
