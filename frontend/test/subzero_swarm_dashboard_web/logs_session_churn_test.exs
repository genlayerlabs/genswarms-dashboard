defmodule SubzeroSwarmDashboardWeb.LogsSessionChurnTest do
  # The logs page's session <select> is rebuilt from every snapshot. When the
  # SELECTED session drops out of a later snapshot (slot recycled between
  # polls), the rebuilt option list silently lost it — the select visually
  # reset while @selected still pointed at the vanished sid. The selected
  # session must stay listed (marked as absent) so the operator's choice
  # survives snapshot churn. Privacy mode deliberately keeps upstream
  # behavior: masked options are index-keyed, so a not-in-snapshot row
  # cannot be added without leaking the sid.
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp snapshot(sessions) do
    %{
      "sessions" =>
        Enum.map(sessions, fn {sid, agent} -> %{"session_id" => sid, "agent" => agent} end)
    }
  end

  defp broadcast(snap),
    do: Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})

  test "the selected session stays selectable when a later snapshot drops it", %{conn: conn} do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _swarm, _sid ->
      {:ok, "one log line"}
    end)

    {:ok, view, _html} = live(conn, "/logs")

    broadcast(snapshot([{"tg:111:0", "agent_0"}, {"tg:222:0", "agent_1"}]))
    render(view)

    view
    |> element(~s(form[phx-change="select"]))
    |> render_change(%{"session_id" => "tg:111:0"})
    assert render(view) =~ "tg:111:0"

    # slot recycled: the next snapshot no longer carries the selected session
    broadcast(snapshot([{"tg:222:0", "agent_1"}]))
    html = render(view)

    assert html =~ "tg:111:0",
           "the selected session must stay in the option list across snapshot churn"

    assert html =~ "not in latest snapshot"
  end

  test "with nothing selected, a churned snapshot adds no synthetic option", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/logs")

    broadcast(snapshot([{"tg:222:0", "agent_1"}]))
    html = render(view)

    refute html =~ "not in latest snapshot"
  end
end
