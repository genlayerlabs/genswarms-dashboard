defmodule SubzeroSwarmDashboardWeb.UsageUnavailableTest do
  # The router /v1/usage endpoint is OPTIONAL. "Deliberately not configured"
  # and "configured but erroring" are different operator situations and must
  # not share one ambiguous empty state. (Ported from micromarkets.)
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "an unconfigured router renders the deliberate-absence state", %{conn: conn} do
    stub(SubzeroSwarmDashboard.RouterClientMock, :usage, fn _opts ->
      {:unavailable, :not_configured}
    end)

    {:ok, view, _html} = live(conn, "/usage")
    send(view.pid, :load)
    html = render(view)

    assert html =~ "Router detail not configured"
    assert html =~ "ROUTER_USAGE_URL"
  end

  test "a configured-but-erroring router renders the failure state", %{conn: conn} do
    stub(SubzeroSwarmDashboard.RouterClientMock, :usage, fn _opts ->
      {:unavailable, {:http, 500}}
    end)

    {:ok, view, _html} = live(conn, "/usage")
    send(view.pid, :load)
    html = render(view)

    assert html =~ "Router detail unavailable"
    refute html =~ "Router detail not configured"
  end
end
