defmodule SubzeroSwarmDashboardWeb.PaginationLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboardWeb.{ExtensionPages, Pagination, SessionsLive}

  setup :set_mox_global

  setup do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"turns" => [], "source" => "store"}}
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"logs" => [], "source" => "unavailable"}}
    end)

    :ok
  end

  defp snapshot(count) do
    %{
      "sessions" =>
        Enum.map(1..count, fn n ->
          %{
            "session_id" => "synthetic:#{n}:0",
            "state" => if(rem(n, 2) == 0, do: "active", else: "idle"),
            "user" => %{"name" => "Member #{n}"},
            "transport_ref" => %{},
            "metadata" => %{}
          }
        end),
      "extensions" => %{}
    }
  end

  test "20k sessions stay bounded during search and can jump to the last page", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    send(view.pid, {:snapshot, snapshot(20_000)})
    render(view)

    assert has_element?(view, "#sessions-total", "20000 total")
    assert has_element?(view, "#sessions-pager", "1–50 of 20000")
    view |> element("#sessions-pager-last") |> render_click()
    assert has_element?(view, "#sessions-pager", "19951–20000 of 20000")
    assert has_element?(view, "tr[phx-value-session_id='synthetic:20000:0']")
    view |> form("#sessions-pager-jump", %{"page" => "2"}) |> render_submit()
    assert has_element?(view, "#sessions-pager", "51–100 of 20000")

    send(view.pid, {:snapshot, snapshot(3)})
    render(view)
    assert has_element?(view, "#sessions-pager", "1–3 of 3")
    send(view.pid, {:snapshot, snapshot(20_000)})
    render(view)

    render_change(view, "search", %{"q" => "Member"})
    assert has_element?(view, "#sessions-pager", "1–50 of 20000")
    refute has_element?(view, "tr[phx-value-session_id='synthetic:51:0']")

    render_click(view, "filter", %{"f" => "live"})
    assert has_element?(view, "#sessions-pager", "1–50 of 10000")
    render_change(view, "search", %{"q" => "Member 19999"})
    assert has_element?(view, "#sessions-pager", "0–0 of 0")
    refute has_element?(view, "tr[phx-value-session_id='synthetic:19999:0']")
  end

  test "page input is bounded and empty collections have an honest range" do
    for value <- [nil, %{}, [], "", "0", "-1", "1.5", "2\n", String.duplicate("9", 1_000)] do
      assert Pagination.page(value) == 1
    end

    assert Pagination.page("12") == 12

    assert {[], %{first: 0, last: 0, total: 0, page: 1, page_count: 1}} =
             Pagination.slice([], 100)
  end

  test "sessions projection keeps whole-scope counts and clamps the requested page" do
    projected = SessionsLive.prepare_snapshot(snapshot(123), %{q: "", filter: "live", page: 999})
    assert length(projected["sessions"]) == 11
    assert projected["_sessions_page"].total == 123
    assert projected["_sessions_page"].filtered_total == 61
    assert projected["_sessions_page"].page == 2
    assert map_size(projected["_sessions_page"].statuses) == 11
  end

  test "search includes the displayed adapter label without a user name" do
    snapshot = %{"sessions" => [%{"session_id" => "synthetic:1:0", "label" => "Contact One"}]}
    projected = SessionsLive.prepare_snapshot(snapshot, %{q: "contact", filter: "all", page: 1})
    assert projected["_sessions_page"].filtered_total == 1
  end

  defp table_page do
    %{
      "id" => "scale",
      "label" => "Scale",
      "sections" => [
        %{
          "type" => "table",
          "columns" => [%{"key" => "score", "label" => "Score"}],
          "rows" => [nil | Enum.map(1..123, &%{"score" => &1, "_cid" => "synthetic:#{&1}:0"})]
        }
      ]
    }
  end

  test "extension projection sorts the complete table and preserves original indices" do
    page =
      ExtensionPages.project_page(table_page(), %{
        ext_sort: %{0 => {"score", :desc}},
        ext_page: %{0 => 3}
      })

    section = hd(page["sections"])
    assert Enum.map(section["rows"], & &1["score"]) == Enum.to_list(23..1//-1)
    assert section["_row_indices"] == Enum.to_list(23..1//-1)
    assert section["_pagination"].total == 123
    assert section["_pagination"].page_count == 3
    {_, targets} = ExtensionPages.extract_row_targets(page, false, %{})
    assert targets[{0, 23}] == "synthetic:23:0"
    assert targets[{0, 1}] == "synthetic:1:0"
  end

  test "extension navigation reaches rows beyond 100 and survives sorting", %{conn: conn} do
    {:ok, view, _} = live(conn, "/extensions/scale")
    snap = put_in(snapshot(123), ["extensions", "dashboard_pages"], [table_page()])
    send(view.pid, {:snapshot, snap})
    render(view)

    assert has_element?(view, "#ext-pager-0", "1–50 of 123")
    view |> element("#ext-pager-0-last") |> render_click()
    assert has_element?(view, "#ext-pager-0", "101–123 of 123")
    assert has_element?(view, "tr[phx-value-session_id='synthetic:123:0']")
    refute has_element?(view, "tr[phx-value-session_id='synthetic:1:0']")

    view |> element("button[phx-value-key='score']") |> render_click()
    view |> element("button[phx-value-key='score']") |> render_click()
    assert has_element?(view, "#ext-pager-0", "1–50 of 123")
    assert has_element?(view, "tr[phx-value-session_id='synthetic:123:0']")
  end

  test "tab tables keep independent pages and only the selected tab carries rows" do
    [table] = table_page()["sections"]

    page = %{
      "sections" => [
        %{
          "type" => "tabs",
          "tabs" => [
            %{"label" => "First", "section" => table},
            %{"label" => "Second", "section" => table}
          ]
        }
      ]
    }

    projected =
      ExtensionPages.project_page(page, %{ext_tab: %{0 => 1}, ext_page: %{"0/0" => 2, "0/1" => 3}})

    [first, second] = hd(projected["sections"])["tabs"]
    assert first["section"] == %{}
    assert second["section"]["_pagination"].first == 101
    assert length(second["section"]["rows"]) == 23
  end

  test "extension metrics are bounded before collecting context session targets" do
    items =
      Enum.map(
        1..20_000,
        &%{"label" => "Metric #{&1}", "value" => &1, "session_id" => "synthetic:#{&1}:0"}
      )

    page = %{
      "id" => "metrics",
      "label" => "Metrics",
      "sections" => [%{"type" => "metrics", "items" => items}]
    }

    projected = ExtensionPages.project_page(page, %{})
    assert length(hd(projected["sections"])["items"]) == 8
    assert :erts_debug.flat_size(projected) < 2_000

    snapshot =
      snapshot(20_000)
      |> put_in(
        ["sessions"],
        Enum.map(1..20_000, &%{"session_id" => "synthetic:#{&1}:0", "state" => "idle"})
      )

    snapshot = put_in(snapshot, ["extensions", "dashboard_pages"], [page])
    view = SubzeroSwarmDashboardWeb.SnapshotView.project(snapshot, %{page_id: "metrics"})
    assert view["_context_sessions"] == []
  end
end
