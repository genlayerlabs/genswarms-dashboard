defmodule SubzeroSwarmDashboardWeb.SnapshotViewTest do
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboardWeb.{DashHooks, ReplyHealth, SnapshotView, SessionsLive}

  defp large_snapshot do
    sessions =
      for i <- 1..20_000 do
        %{
          "session_id" => "test:#{i}:0",
          "last_activity" => "2020-01-01T00:00:00Z",
          "user" => %{"handle" => "user_#{i}"},
          "agent" => if(i == 20_000, do: "agent_1"),
          "state" => "idle"
        }
      end

    %{
      "sessions" => sessions,
      "summary" => %{"sessions" => 20_000},
      "extensions" => %{
        "consumers" => %{
          "count" => 20_000,
          "items" => Enum.map(sessions, &%{"session_id" => &1["session_id"]})
        },
        "replies" => %{"available" => true, "items" => []},
        "dashboard_pages" => [
          %{
            "id" => "large",
            "label" => "Large table",
            "sections" => [%{"type" => "table", "rows" => sessions}]
          }
        ]
      }
    }
  end

  test "overview keeps full health/population totals with only live and preview rows" do
    source = large_snapshot()
    projected = SnapshotView.project(source, %{})
    assert projected["summary"]["sessions"] == 20_000
    assert projected["extensions"]["consumers"]["count"] == 20_000
    assert length(projected["sessions"]) <= 51
    assert Enum.any?(projected["sessions"], &(&1["session_id"] == "test:20000:0"))
    assert ReplyHealth.counts(projected, nil, System.os_time(:second)).stale == 20_000
    assert get_in(projected, ["extensions", "dashboard_pages", Access.at(0), "sections"]) == nil
    assert :erts_debug.flat_size(projected) * :erlang.system_info(:wordsize) < 200_000
  end

  test "sessions page is bounded while an off-page inspector remains reachable" do
    projected =
      SnapshotView.project(large_snapshot(), %{
        dashboard_view: SessionsLive,
        page: 2,
        q: "",
        filter: "all",
        story: nil,
        inspect: %{"session_id" => "test:19999:0"}
      })

    assert length(projected["sessions"]) == 50
    assert projected["_sessions_page"].total == 20_000
    assert Enum.any?(projected["_context_sessions"], &(&1["session_id"] == "test:19999:0"))
    assert DashHooks.inspect_value(DashHooks.inspect_lookup(projected), true, "test:19999:0")
  end

  test "layout excludes unused payloads and privacy inspect tokens survive row reorder" do
    source = large_snapshot()
    layout = DashHooks.layout_snapshot(source, true)
    assert Map.keys(layout) -- ["swarm", "dashboard_title", "extensions"] == []

    assert get_in(layout, ["extensions", "dashboard_pages", Access.at(0), "label"]) ==
             "Large table"

    assert :erts_debug.flat_size(layout) < 200
    first = DashHooks.inspect_lookup(source)
    reversed = DashHooks.inspect_lookup(%{"sessions" => Enum.reverse(source["sessions"])})

    assert DashHooks.inspect_value(first, true, "test:1:0") ==
             DashHooks.inspect_value(reversed, true, "test:1:0")
  end
end
