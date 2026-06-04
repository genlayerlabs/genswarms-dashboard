defmodule SubzeroSwarmDashboardWeb.DashboardLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{SwarmClientMock, RouterClientMock}

  setup :set_mox_global

  @snap %{
    "swarm" => "wingston",
    "status" => "running",
    "uptime_s" => 5821,
    "data_source" => "in_process",
    "generated_at" => "2026-06-03T15:22:01Z",
    "summary" => %{"agents" => 1, "objects" => 6, "pool" => %{"size" => 2048, "leased" => 1, "idle" => 2047}},
    "nodes" => [
      %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
      %{"name" => "wingston_agent_0", "type" => "agent", "state" => "active", "session_id" => "tg:1:0"}
    ],
    "edges" => [%{"from" => "ingress", "to" => "policy"}],
    "sessions" => [
      %{
        "session_id" => "tg:1:0",
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-06-03T15:22:01Z",
        "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"},
        "metadata" => %{"chat_type" => "dm"}
      }
    ],
    "extensions" => %{
      "consumers" => %{"count" => 1, "items" => [%{"session_id" => "tg:1:0", "mode" => "scout", "opt_out" => false}]}
    },
    "warnings" => []
  }

  setup do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)
    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"session_id" => "tg:1:0", "turns" => [], "source" => "unavailable"}}
    end)
    stub(SwarmClientMock, :events, fn _, _ -> {:ok, []} end)
    stub(SwarmClientMock, :session_logs, fn _, _ -> {:ok, %{"logs" => [], "source" => "unavailable"}} end)
    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    :ok
  end

  defp push_snap(view) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, @snap})
    render(view)
  end

  test "overview renders the snapshot", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Overview"
    html = push_snap(view)
    assert html =~ "in_process"
    assert html =~ "2048"
  end

  test "topology mounts and lists nodes in the fallback table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/topology")
    assert html =~ "Topology"
    assert push_snap(view) =~ "ingress"
  end

  test "snapshot pushes the classified graph to the topology hook", %{conn: conn} do
    {:ok, view, _} = live(conn, "/topology")
    push_snap(view)
    assert_push_event(view, "topology:graph", %{nodes: nodes, edges: edges})
    assert Enum.any?(nodes, &(&1.data.id == "ingress" and &1.data.type == "object"))
    assert Enum.any?(nodes, &(&1.data.id == "wingston_agent_0" and &1.data.type == "agent"))
    assert Enum.any?(edges, &match?(%{data: %{source: "ingress", target: "policy"}}, &1))
  end

  test "live agent_status event pushes an incremental update (and crashes no page)", %{conn: conn} do
    {:ok, topo, _} = live(conn, "/topology")
    {:ok, overview, _} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      SubzeroSwarmDashboard.PubSub,
      "feed",
      {:event, "agent_status", %{"agent" => "wingston_agent_0", "state" => "idle"}}
    )

    # Topology forwards it to the hook; other pages safely ignore it (catch-all).
    assert_push_event(topo, "topology:event", %{
      type: "agent_status",
      payload: %{"agent" => "wingston_agent_0", "state" => "idle"}
    })

    assert render(overview) =~ "Overview"
  end

  test "sessions lists from the snapshot", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    html = push_snap(view)
    assert html =~ "tg:1:0"
    assert html =~ "telegram"
  end

  test "sessions search filters by session_id / transport_ref", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)
    # "telegram" is the per-session transport badge — only in the sessions table,
    # not the consumers panel (which would also show the session_id).
    assert render(view) =~ "telegram"

    assert view |> element("form") |> render_change(%{"q" => "999999"}) =~ "No sessions match"
    assert view |> element("form") |> render_change(%{"q" => "1"}) =~ "telegram"
  end

  test "session detail loads a transcript", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sessions/tg:1:0")
    assert html =~ "Transcript"
  end

  test "events page mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/events")
    assert html =~ "Events"
  end

  test "events: server filters pass through + client contains filter narrows rows", %{conn: conn} do
    parent = self()

    stub(SwarmClientMock, :events, fn _swarm, opts ->
      send(parent, {:events_opts, opts})

      {:ok,
       [
         %{"timestamp" => "t1", "level" => "info", "category" => "agent", "agent" => "a0", "message" => "spawned agent"},
         %{"timestamp" => "t2", "level" => "error", "category" => "router", "agent" => "r", "message" => "invalid route"}
       ]}
    end)

    {:ok, view, _} = live(conn, "/events")
    assert render(view) =~ "spawned agent"

    # server-side filters reach SwarmClient.events
    view |> element("form") |> render_change(%{"level" => "error", "category" => "router", "agent" => "r", "minutes" => "60"})
    assert_receive {:events_opts, %{level: "error", category: "router", agent: "r", minutes: 60}}

    # client-side "contains" narrows the rendered rows
    html = view |> element("form") |> render_change(%{"contains" => "invalid"})
    assert html =~ "invalid route"
    refute html =~ "spawned agent"
  end

  test "usage shows unavailable when the router has no usage endpoint", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/usage")
    assert html =~ "Usage"
  end

  test "logs page mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/logs")
    assert html =~ "Logs"
  end

  test "logs: selecting a session loads its raw slot output", %{conn: conn} do
    stub(SwarmClientMock, :session_logs, fn _swarm, "tg:1:0" ->
      {:ok, %{"source" => "slot", "logs" => [%{"timestamp" => "t1", "role" => "user", "content" => "hello there"}]}}
    end)

    {:ok, view, _} = live(conn, "/logs")
    push_snap(view)
    view |> element("form") |> render_change(%{"session_id" => "tg:1:0"})
    html = render(view)
    assert html =~ "hello there"
    assert html =~ "slot"
  end
end
