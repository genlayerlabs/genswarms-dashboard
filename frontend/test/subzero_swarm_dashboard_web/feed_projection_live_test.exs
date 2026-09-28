defmodule SubzeroSwarmDashboardWeb.FeedProjectionLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  alias SubzeroSwarmDashboard.{SwarmFeed, SwarmClientMock, RouterClientMock}

  setup :set_mox_global

  test "shared-feed sessions remain bounded through search, last-page navigation and polling", %{
    conn: conn
  } do
    rows = for i <- 1..20_000, do: %{"session_id" => "test:#{i}:0", "label" => "Contact #{i}"}

    snapshot = %{
      "swarm" => "wingston",
      "sessions" => rows,
      "summary" => %{"agents" => 0},
      "extensions" => %{"consumers" => %{"available" => true, "count" => 20_000, "items" => []}}
    }

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, snapshot} end)
    SwarmFeed.subscribe()
    start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, _}, 2_000
    {:ok, view, _} = live(conn, "/sessions")
    assert has_element?(view, "#sessions-total", "20000 total")
    assert has_element?(view, "#sessions-table tr.row-press")
    view |> element("#sessions-pager-last") |> render_click()
    assert has_element?(view, "#sessions-pager", "19951–20000 of 20000")
    view |> element("#sessions-search") |> render_change(%{"q" => "Contact"})
    assert has_element?(view, "#sessions-pager", "1–50 of 20000")
    state = :sys.get_state(view.pid)
    assert length(state.socket.assigns.snapshot["sessions"]) == 50
    refute Map.has_key?(state.socket.assigns, :snapshot_source)
    :erlang.garbage_collect(view.pid)
    assert {:memory, bytes} = Process.info(view.pid, :memory)
    assert bytes < 3_000_000
  end

  test "a mount seeded after a failed poll shows stale data as disconnected", %{conn: conn} do
    parent = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(parent, {:poll, self()})

      receive do
        {:reply, response} -> response
      end
    end)

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    SwarmFeed.subscribe()
    feed = start_supervised!(SwarmFeed)
    assert_receive {:poll, task}, 2_000
    send(task, {:reply, {:ok, %{"sessions" => [], "summary" => %{"agents" => 0}}}})
    assert_receive {:snapshot_ready, _}, 2_000
    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:poll, task}, 2_000
    send(task, {:reply, {:error, :timeout}})
    assert_receive {:disconnected, _, :timeout}, 2_000
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, ".alert", "Swarm unreachable")
  end

  test "suppression reclassifies the complete cache during an upstream outage", %{conn: conn} do
    now = System.os_time(:second)
    sid = "test:1:0"

    source = %{
      "sessions" => [
        %{
          "session_id" => sid,
          "last_activity" => DateTime.from_unix!(now - 300) |> DateTime.to_iso8601()
        }
      ],
      "summary" => %{"agents" => 0},
      "extensions" => %{"replies" => %{"available" => true, "items" => []}}
    }

    responses = start_supervised!({Agent, fn -> {:ok, source} end})
    stub(SwarmClientMock, :dashboard, fn _ -> Agent.get(responses, & &1) end)
    SwarmFeed.subscribe()
    feed = start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, _}, 2_000
    {:ok, view, _} = live(conn, "/sessions")

    assert :sys.get_state(view.pid).socket.assigns.snapshot["_sessions_page"].statuses[sid] ==
             :unanswered

    Agent.update(responses, fn _ -> {:error, :timeout} end)
    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:disconnected, _, :timeout}, 2_000

    send(
      view.pid,
      {:story,
       %{baseline_at: DateTime.utc_now(), story: [%{kind: "reply_suppressed", cid: sid, ts: now}]}}
    )

    render(view)
    snapshot = :sys.get_state(view.pid).socket.assigns.snapshot
    assert snapshot["_sessions_page"].statuses[sid] == :suppressed
    assert snapshot["_reply_health"].suppressed == 1
    assert snapshot["_reply_health"].unanswered == 0
  end

  test "queued stale failures cannot overwrite the latest recovered connection", %{conn: conn} do
    source = %{"sessions" => [], "summary" => %{"agents" => 0}}
    responses = start_supervised!({Agent, fn -> {:ok, source} end})
    stub(SwarmClientMock, :dashboard, fn _ -> Agent.get(responses, & &1) end)
    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    SwarmFeed.subscribe()
    feed = start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, _}, 2_000
    {:ok, view, _} = live(conn, "/")
    :sys.suspend(view.pid)
    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:snapshot_ready, _}, 2_000
    Agent.update(responses, fn _ -> {:error, :timeout} end)
    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:disconnected, _, :timeout}, 2_000
    Agent.update(responses, fn _ -> {:ok, source} end)
    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:snapshot_ready, recovered_revision}, 2_000
    :sys.resume(view.pid)
    render(view)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.conn_status == :connected
    assert assigns.snapshot_revision == recovered_revision
  end

  test "story projection cannot consume the revision before topology receives its callback", %{
    conn: conn
  } do
    source = %{
      "sessions" => [],
      "nodes" => [%{"type" => "agent", "name" => "agent_a"}],
      "summary" => %{"agents" => 0}
    }

    responses = start_supervised!({Agent, fn -> {:ok, source} end})
    stub(SwarmClientMock, :dashboard, fn _ -> Agent.get(responses, & &1) end)
    SwarmFeed.subscribe()
    feed = start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, _}, 2_000
    {:ok, view, _} = live(conn, "/topology")
    assert_push_event(view, "pipeline:agents", %{agents: ["agent_a"]})
    :sys.suspend(view.pid)

    send(
      view.pid,
      {:story,
       %{story: [%{kind: "reply_suppressed", cid: "test:1:0", ts: System.os_time(:second)}]}}
    )

    Agent.update(responses, fn _ ->
      {:ok, put_in(source, ["nodes", Access.at(0), "name"], "agent_b")}
    end)

    send(feed, {:timeout, :sys.get_state(feed).timer, :poll})
    assert_receive {:snapshot_ready, _}, 2_000
    :sys.resume(view.pid)
    assert_push_event(view, "pipeline:agents", %{agents: ["agent_b"]})
  end

  test "a first poll failure changes an existing empty page from connecting to disconnected", %{
    conn: conn
  } do
    parent = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(parent, {:waiting, self()})

      receive do
        :fail -> {:error, :timeout}
      end
    end)

    SwarmFeed.subscribe()
    start_supervised!(SwarmFeed)
    assert_receive {:waiting, task}, 2_000
    {:ok, view, _} = live(conn, "/sessions")
    send(task, :fail)
    assert_receive {:disconnected, _, :timeout}, 2_000
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.conn_status == :disconnected
  end
end
