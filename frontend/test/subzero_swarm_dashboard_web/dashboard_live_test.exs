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

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
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

  test "sessions show a reply-health badge from the sender's deliveries extension", %{conn: conn} do
    in_unix = "2026-06-03T15:22:01Z" |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()

    {:ok, view, _} = live(conn, "/sessions")

    # answered: a delivery AFTER the last inbound
    answered = put_in(@snap, ["extensions", "deliveries"],
      %{"items" => [%{"session_id" => "tg:1:0", "at" => in_unix + 10, "status" => "sent"}]})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, answered})
    assert render(view) =~ "answered"

    # unanswered: old inbound, no delivery at all -> flagged + counted in the header
    unanswered = put_in(@snap, ["extensions", "deliveries"], %{"items" => []})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, unanswered})
    html = render(view)
    assert html =~ "no reply"
    assert html =~ "unanswered"
  end

  test "clicking a session opens the shared inspector, Esc-close clears it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)

    html = view |> element("tr[phx-value-session_id='tg:1:0']") |> render_click()
    # The inspector now shows the FULL detail inline — durable Conversation + live
    # Agent activity — so there is no separate "open full session" step in the panel.
    # (The sessions table keeps its own row deep-link, hence no global refute here.)
    assert html =~ "Conversation"
    assert html =~ "Agent activity"

    refute view |> element("button[aria-label='Close']") |> render_click() =~ "Agent activity"
  end

  test "session detail loads a transcript", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sessions/tg:1:0")
    assert html =~ "Conversation"
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

    assert html =~ "Agent activity"
    assert html =~ "agent_server"
    assert html =~ "ping"
    assert html =~ "pong"
    assert html =~ "2026-06-04T10:00:01Z"
  end

  test "session detail renders the live slot's skills as the system-prompt block", %{conn: conn} do
    stub(SwarmClientMock, :session_skills, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "slot",
         "skills" => [%{"name" => "browse.md", "content" => "# Browse\nRender pages."}]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "System prompt · skills"
    assert html =~ "browse.md"
    assert html =~ "Render pages."
  end

  test "session detail says skills are unavailable when the session has no live slot", %{conn: conn} do
    # default session_skills stub is source: unavailable
    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "System prompt · skills"
    assert html =~ "Unavailable (no live slot"
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

  defp v2_usage do
    %{
      "schema_version" => 2,
      "detail_level" => "full",
      "totals" => %{
        "requests" => 1240,
        "errors" => 0,
        "tokens_in" => 1_000_000,
        "tokens_out" => 2_100_000,
        "tokens_total" => 3_100_000,
        "latency_ms_avg" => 420.0,
        "latency_ms_max" => 980.0,
        "error_rate" => 0.0,
        "last_seen" => System.os_time(:second) - 120
      },
      "by_served_model" => %{
        "gpt-5.5" => %{"requests" => 1240, "tokens_total" => 3_100_000, "error_rate" => 0.0, "latency_ms_avg" => 420.0, "latency_ms_max" => 980.0}
      },
      "by_provider" => %{"openai" => %{"requests" => 1240, "tokens_total" => 3_100_000}},
      "by_route" => %{"profile:medium" => %{"requests" => 1240, "tokens_total" => 3_100_000}},
      "by_model_family" => %{"gpt-5.5-codex" => %{"requests" => 1240, "tokens_total" => 3_100_000}},
      "consumer_settings" => %{"status" => "active", "allowed_routes" => [], "effective_per_min" => 600, "burst" => 60},
      "key" => %{"sha256_prefix" => "ab12cd34", "status" => "active"},
      "health_summary" => %{"state" => "healthy", "success_rate" => 1.0, "success_count" => 1240, "request_count" => 1240, "status_counts" => %{"200" => 1240}, "route_failures" => 0},
      "route_health" => [%{"route" => "profile:medium", "state" => "healthy", "served_model_id" => "gpt-5.5"}],
      "recent" => [%{"ts" => System.os_time(:second) - 60, "status" => 200, "served_model_id" => "gpt-5.5", "path" => "/v1/chat/completions", "latency_ms" => 420.0, "tokens_total" => 2537}],
      "security" => %{"sanitized" => true, "raw_api_key_exposed" => false}
    }
  end

  test "usage renders schema v2 detail (totals, breakdowns, health, key, recent)", %{conn: conn} do
    payload = v2_usage()
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)
    stub(RouterClientMock, :usage, fn _ -> {:ok, payload} end)

    {:ok, view, _} = live(conn, "/usage")
    html = render(view)

    assert html =~ "Requests"
    # tokens formatted with thousands separators
    assert html =~ "3,100,000"
    # all four breakdown tables + a served-model row
    assert html =~ "By served model"
    assert html =~ "By provider"
    assert html =~ "By route"
    assert html =~ "By model family"
    assert html =~ "gpt-5.5"
    # health + key metadata + recent
    assert html =~ "healthy"
    assert html =~ "ab12cd34"
    assert html =~ "Recent requests"
    assert html =~ "schema v2"
  end

  test "usage range buttons re-query the router with a since bound", %{conn: conn} do
    test_pid = self()

    stub(RouterClientMock, :usage, fn opts ->
      send(test_pid, {:usage_opts, opts})
      {:ok, v2_usage()}
    end)

    {:ok, view, _} = live(conn, "/usage")
    # initial load uses the default "all" window → no since bound
    assert_receive {:usage_opts, opts_all}
    refute Map.has_key?(opts_all, :since)

    view |> element("button[phx-value-window='1h']") |> render_click()
    assert_receive {:usage_opts, %{since: since}}
    assert is_integer(since)
  end

  test "logs page mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/logs")
    assert html =~ "Logs"
  end

  describe "activity classification (CoreComponents.classify_activity/1)" do
    alias SubzeroSwarmDashboardWeb.CoreComponents

    test "an orchestrator-relayed user message is the user, prefix stripped" do
      assert %{kind: :user, text: "what campaigns"} =
               CoreComponents.classify_activity(%{"role" => "user", "content" => "[From orchestrator] what campaigns", "timestamp" => "t"})
    end

    test "an inter-object [From policy] message is noise, labeled by source" do
      row = CoreComponents.classify_activity(%{"role" => "user", "content" => ~s([From policy] {"campaigns":[]})})
      assert row.kind == :noise
      assert row.label == "policy →"
    end

    test "a tool shell call is noise" do
      assert %{kind: :noise} =
               CoreComponents.classify_activity(%{"role" => "tool", "content" => ~s(shell: swarm-msg send policy '{"action":"campaigns"}')})
    end

    test "an exit result is noise" do
      assert %{kind: :noise} = CoreComponents.classify_activity(%{"role" => "res", "content" => "[exit:0] "})
    end

    test "a natural-language assistant turn is chat" do
      assert %{kind: :assistant, text: "Sent! Here's the full list"} =
               CoreComponents.classify_activity(%{"role" => "asst", "content" => "Sent! Here's the full list"})
    end

    test "an assistant tool-call emitted as text is flagged not-delivered, not shown as a reply" do
      blob = ~s({"cmd": "cat > /workspace/reply.json <<JSON\\n{\\"action\\":\\"reply\\",\\"text\\":\\"Yo welcome\\"}\\nJSON\\nswarm-msg send sender -f /workspace/reply.json"})
      # Previously this masked as a clean :assistant reply; now it must surface as
      # an un-executed tool call (the reply was never actually sent).
      assert %{kind: :tool_intent, text: "Yo welcome"} = CoreComponents.classify_activity(%{"role" => "asst", "content" => blob})
    end

    test "a <tool_call>-wrapped assistant turn is flagged not-delivered" do
      assert %{kind: :tool_intent} =
               CoreComponents.classify_activity(%{"role" => "assistant", "content" => ~s(<tool_call>\n{"cmd": "echo hi"}\n</tool_call>)})
    end

    test "an executed reply (shell tool actually ran swarm-msg send) shows as sent" do
      tool = ~s(shell: cat > /workspace/reply.json <<JSON\n{"action":"reply","text":"Hello there"}\nJSON\nswarm-msg send sender -f /workspace/reply.json)
      assert %{kind: :sent, text: "Hello there"} =
               CoreComponents.classify_activity(%{"role" => "tool", "content" => tool})
    end
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
