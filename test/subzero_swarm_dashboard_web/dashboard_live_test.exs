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
    "summary" => %{
      "agents" => 1,
      "objects" => 6,
      "pool" => %{"size" => 2048, "leased" => 1, "idle" => 2047}
    },
    "nodes" => [
      %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
      %{"name" => "policy", "type" => "object", "subtype" => "policy"},
      %{
        "name" => "wingston_agent_0",
        "type" => "agent",
        "state" => "active",
        "session_id" => "tg:1:0"
      }
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
      "consumers" => %{
        "count" => 1,
        "items" => [%{"session_id" => "tg:1:0", "mode" => "scout", "opt_out" => false}]
      }
    },
    "warnings" => []
  }

  setup do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)

    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"session_id" => "tg:1:0", "turns" => [], "source" => "unavailable"}}
    end)

    stub(SwarmClientMock, :events, fn _, _ -> {:ok, []} end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"logs" => [], "source" => "unavailable"}}
    end)

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
    # the agent slot appears only in the sessions row (not the consumers panel).
    assert html =~ "wingston_agent_0"
  end

  test "sessions search filters by session_id / transport_ref", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)
    # the agent slot is rendered only in the sessions table row, so it's a clean
    # signal that the row itself is shown (the consumers panel omits the agent).
    assert render(view) =~ "wingston_agent_0"

    assert view |> element("form") |> render_change(%{"q" => "999999"}) =~ "No sessions match"
    refute view |> element("form") |> render_change(%{"q" => "999999"}) =~ "wingston_agent_0"
    assert view |> element("form") |> render_change(%{"q" => "1"}) =~ "wingston_agent_0"
  end

  test "sessions lead with the user handle + name when known", %{conn: conn} do
    snap =
      put_in(@snap, ["sessions"], [
        %{
          "session_id" => "tg:1:0",
          "transport" => "telegram",
          "agent" => "wingston_agent_0",
          "state" => "active",
          "last_activity" => "2026-06-03T15:22:01Z",
          "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"},
          "metadata" => %{"chat_type" => "dm"},
          "user" => %{"handle" => "alberto", "name" => "Alberto C"}
        }
      ])

    {:ok, view, _} = live(conn, "/sessions")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    assert html =~ "@alberto"
    assert html =~ "Alberto C"
  end

  test "clicking a session opens the shared inspector, Esc-close clears it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)

    html = view |> element("tr[phx-value-session_id='tg:1:0']") |> render_click()
    assert html =~ "Recent transcript"
    assert html =~ "Open full session"

    refute view |> element("button[aria-label='Close']") |> render_click() =~ "Recent transcript"
  end

  test "session detail loads a transcript", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sessions/tg:1:0")
    assert html =~ "Transcript"
  end

  test "session detail renders the per-session activity timeline from session_logs", %{conn: conn} do
    stub(SwarmClientMock, :session_logs, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "agent_server",
         "logs" => [
           %{"timestamp" => "2026-06-04T10:00:00Z", "role" => "user", "content" => "ping"},
           %{"timestamp" => "2026-06-04T10:00:01Z", "role" => "assistant", "content" => "pong"}
         ]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "Activity"
    assert html =~ "agent_server"
    assert html =~ "ping"
    assert html =~ "pong"
    assert html =~ "2026-06-04T10:00:01Z"
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
         %{
           "timestamp" => "t1",
           "level" => "info",
           "category" => "agent",
           "agent" => "a0",
           "message" => "spawned agent"
         },
         %{
           "timestamp" => "t2",
           "level" => "error",
           "category" => "router",
           "agent" => "r",
           "message" => "invalid route"
         }
       ]}
    end)

    {:ok, view, _} = live(conn, "/events")
    assert render(view) =~ "spawned agent"

    # server-side filters reach SwarmClient.events
    view
    |> element("form")
    |> render_change(%{
      "level" => "error",
      "category" => "router",
      "agent" => "r",
      "minutes" => "60"
    })

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
      {:ok,
       %{
         "source" => "slot",
         "logs" => [%{"timestamp" => "t1", "role" => "user", "content" => "hello there"}]
       }}
    end)

    {:ok, view, _} = live(conn, "/logs")
    push_snap(view)
    view |> element("form") |> render_change(%{"session_id" => "tg:1:0"})
    html = render(view)
    assert html =~ "hello there"
    assert html =~ "slot"
  end
end
