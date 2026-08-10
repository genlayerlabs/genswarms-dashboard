defmodule SubzeroSwarmDashboardWeb.SwarmControllerTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Mox

  alias SubzeroSwarmDashboard.{FleetCatalog, SwarmClientMock}

  setup :set_mox_global

  setup do
    stub(SwarmClientMock, :swarms, fn ->
      {:ok, [%{"name" => "strategivm"}, %{"name" => "project-a"}]}
    end)

    start_supervised!(FleetCatalog)
    _ = :sys.get_state(FleetCatalog)
    assert "project-a" in FleetCatalog.current()
    :ok
  end

  test "stores only a discovered swarm in the browser session", %{conn: conn} do
    conn = post(conn, ~p"/swarm/select", %{"swarm" => "project-a"})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :selected_swarm) == "project-a"
  end

  test "rejects an unknown swarm", %{conn: conn} do
    conn = post(conn, ~p"/swarm/select", %{"swarm" => "not-in-this-beam"})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :selected_swarm) == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That swarm is not available"
  end
end
