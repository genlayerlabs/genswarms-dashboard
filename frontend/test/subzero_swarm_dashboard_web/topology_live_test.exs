defmodule SubzeroSwarmDashboardWeb.TopologyLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "mounts the pipeline hook el (unique id + phx-update=ignore) and pushes the layout", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/topology")

    assert has_element?(view, ~s(#pipeline[phx-hook="Pipeline"][phx-update="ignore"]))
    refute has_element?(view, ~s(#pipeline[data-debug]))
    assert_push_event(view, "pipeline:init", %{nodes: [], edges: [], chatter: []})
  end

  test "?debug=1 sets data-debug on the hook el (read by the hook at mount)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/topology?debug=1")

    assert has_element?(view, ~s(#pipeline[data-debug="1"]))
  end

  test "a display event is forwarded to the hook as pipeline:event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/topology")

    ev = %{
      "kind" => "routed",
      "cid" => "tg:1:0",
      "slot" => "wingston_agent_0",
      "seq" => 1,
      "ts" => 1.0
    }

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:display_event, ev})

    assert_push_event(view, "pipeline:event", %{"kind" => "routed", "slot" => "wingston_agent_0"})
  end

  test "a snapshot replaces the canvas topology and carries every real agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/topology")
    assert_push_event(view, "pipeline:init", %{nodes: []})

    snap = %{
      "nodes" => [
        %{"type" => "agent", "name" => "engendrador"},
        %{"type" => "agent", "name" => "conservator"},
        %{"type" => "object", "name" => "policy"},
        %{"type" => "object", "name" => "commands"}
      ],
      "edges" => [
        %{"from" => "engendrador", "to" => "policy"},
        %{"from" => "policy", "to" => "conservator"},
        %{"from" => "commands", "to" => "policy"}
      ]
    }

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})

    assert_push_event(view, "pipeline:init", layout)

    # agents are NOT fixed layout nodes — they live in the hook's centered grid
    assert Enum.map(layout.nodes, & &1.name) |> Enum.sort() == ["commands", "policy"]

    # durable rails only between fixed nodes; agent legs animate as live traffic
    assert layout.edges == [%{from: "commands", to: "policy"}]

    refute Enum.any?(layout.nodes, &(&1.name == "rally"))
    assert_push_event(view, "pipeline:agents", %{agents: agents})
    assert agents == ["conservator", "engendrador"]
  end

  test "a snapshot cached at mount pushes the agent grid immediately", %{conn: conn} do
    import Mox
    set_mox_global(%{})

    snap = %{
      "nodes" => [
        %{"type" => "agent", "name" => "agent_a"},
        %{"type" => "object", "name" => "policy"}
      ],
      "edges" => [%{"from" => "agent_a", "to" => "policy"}]
    }

    stub(SubzeroSwarmDashboard.SwarmClientMock, :dashboard, fn _ -> {:ok, snap} end)
    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, "feed")
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)
    assert_receive {:snapshot, ^snap}, 2_000

    {:ok, view, _html} = live(conn, "/topology")

    # both pushed AT MOUNT — the next feed poll is seconds away, the
    # assert_push_event timeout is 100ms
    assert_push_event(view, "pipeline:init", %{nodes: [%{name: "policy"}]})
    assert_push_event(view, "pipeline:agents", %{agents: ["agent_a"]})
  end

  describe "pipeline_layout/1" do
    alias SubzeroSwarmDashboardWeb.TopologyLive

    test "agent-less DAGs still layer sources before their target" do
      snapshot = %{
        "nodes" => [
          %{"name" => "engendrador", "type" => "object"},
          %{"name" => "conservator", "type" => "object"},
          %{"name" => "adjudicador", "type" => "object"}
        ],
        "edges" => [
          %{"from" => "engendrador", "to" => "adjudicador"},
          %{"from" => "conservator", "to" => "adjudicador"},
          %{"from" => "missing", "to" => "adjudicador"}
        ]
      }

      layout = TopologyLive.pipeline_layout(snapshot)
      by_name = Map.new(layout.nodes, &{&1.name, &1})

      assert Map.keys(by_name) |> Enum.sort() == ["adjudicador", "conservator", "engendrador"]

      assert layout.edges == [
               %{from: "conservator", to: "adjudicador"},
               %{from: "engendrador", to: "adjudicador"}
             ]

      assert by_name["engendrador"].x < by_name["adjudicador"].x
      assert by_name["conservator"].x < by_name["adjudicador"].x
      assert Enum.all?(layout.nodes, &(&1.kind == "obj"))
    end

    test "agents are excluded and objects band by agent adjacency" do
      snapshot = %{
        "nodes" => [
          %{"name" => "agent_0", "type" => "agent"},
          %{"name" => "agent_1", "type" => "agent"},
          %{"name" => "policy", "type" => "object"},
          %{"name" => "tips", "type" => "object"},
          %{"name" => "sender", "type" => "object"},
          %{"name" => "commands", "type" => "object"}
        ],
        "edges" => [
          %{"from" => "policy", "to" => "agent_0"},
          %{"from" => "agent_0", "to" => "policy"},
          %{"from" => "tips", "to" => "agent_1"},
          %{"from" => "agent_0", "to" => "sender"},
          %{"from" => "commands", "to" => "policy"}
        ]
      }

      layout = TopologyLive.pipeline_layout(snapshot)
      by_name = Map.new(layout.nodes, &{&1.name, &1})

      # agents live in the hook's centered grid, never in the fixed layout
      assert Map.keys(by_name) |> Enum.sort() == ["commands", "policy", "sender", "tips"]

      # services (talk to agents) band on top, bookkeeping below the agent grid
      for service <- ["policy", "tips", "sender"], do: assert(by_name[service].y < 0.3)
      assert by_name["commands"].y > 0.7

      # durable rails only between fixed nodes
      assert layout.edges == [%{from: "commands", to: "policy"}]
      assert layout.agent_span_y == 0.66
    end

    test "a fully cyclic agents<->services graph never collapses into one column" do
      agents = for i <- 0..19, do: "agent_#{i}"
      services = ~w(policy tips browser sender)
      bookkeeping = ~w(commands rally cron llm_proxy metrics)

      snapshot = %{
        "nodes" =>
          Enum.map(agents, &%{"name" => &1, "type" => "agent"}) ++
            Enum.map(services ++ bookkeeping, &%{"name" => &1, "type" => "object"}),
        "edges" =>
          for(
            s <- services,
            a <- agents,
            do: [%{"from" => s, "to" => a}, %{"from" => a, "to" => s}]
          )
          |> List.flatten()
          |> Kernel.++([
            %{"from" => "commands", "to" => "rally"},
            %{"from" => "rally", "to" => "commands"},
            %{"from" => "cron", "to" => "llm_proxy"},
            %{"from" => "llm_proxy", "to" => "cron"}
          ])
      }

      layout = TopologyLive.pipeline_layout(snapshot)
      by_name = Map.new(layout.nodes, &{&1.name, &1})

      assert Map.keys(by_name) |> Enum.sort() == Enum.sort(services ++ bookkeeping)
      for s <- services, do: assert(by_name[s].y < 0.3)
      for b <- bookkeeping, do: assert(by_name[b].y > 0.7)

      # no two fixed nodes may share a position (the smear regression)
      positions = Enum.map(layout.nodes, &{&1.x, &1.y})
      assert positions == Enum.uniq(positions)
    end

    test "an oversized band wraps into extra rows and shrinks the agent span" do
      snapshot = %{
        "nodes" =>
          [%{"name" => "agent_0", "type" => "agent"}] ++
            for(i <- 1..9, do: %{"name" => "obj_#{i}", "type" => "object"}),
        "edges" => []
      }

      layout = TopologyLive.pipeline_layout(snapshot)

      rows = layout.nodes |> Enum.map(& &1.y) |> Enum.uniq() |> Enum.sort()
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1 > 0.7))
      assert layout.agent_span_y < 0.66
    end

    test "an edgeless swarm gets a compact grid without invented nodes" do
      snapshot = %{
        "nodes" =>
          for name <- ~w(fleet watch fundare sender tracker ingress dashboard seed) do
            %{"name" => name, "type" => if(name == "seed", do: "agent", else: "object")}
          end,
        "edges" => []
      }

      layout = TopologyLive.pipeline_layout(snapshot)

      assert Enum.map(layout.nodes, & &1.name) |> Enum.sort() ==
               ~w(dashboard fleet fundare ingress sender tracker watch)

      assert layout.edges == []
      refute Enum.any?(layout.nodes, &(&1.name == "seed"))
      assert layout.nodes |> Enum.map(& &1.x) |> Enum.uniq() |> length() > 1
    end

    test "nil and malformed topology data fail closed to an empty layout" do
      assert TopologyLive.pipeline_layout(nil).nodes == []

      assert TopologyLive.pipeline_layout(%{
               "nodes" => [%{"name" => nil}, "bad"],
               "edges" => [%{"from" => "bad", "to" => "missing"}]
             }).edges == []
    end
  end

  test "the in-flight strip renders TRUE state from the story summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/topology")

    summary = %{
      feed_status: :ok,
      feed_age_s: 0,
      in_flight: [
        %{
          cid: "tg:568:0",
          user: "568",
          agent: "wingston_agent_0",
          count: 1,
          opened_at: 1.0,
          elapsed_s: 12.4,
          stalled: false,
          activity: "waiting on browser"
        }
      ],
      agents: [],
      kpis: %{},
      issues: [],
      story: []
    }

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:story, summary})
    html = render(view)

    assert html =~ "@568"
    assert html =~ "waiting on browser"
    assert html =~ "12.4s"
    refute html =~ "feed unavailable"
  end

  describe "agent_handles/1 (canvas avatar seed: slot => seed)" do
    alias SubzeroSwarmDashboardWeb.TopologyLive

    test "avatar seed is handle first, then label / name, then session id" do
      snap = %{
        "sessions" => [
          %{
            "agent" => "wingston_agent_1",
            "session_id" => "telegram:111",
            "state" => "active",
            "user" => %{"handle" => "kongtouquan"}
          },
          %{
            "agent" => "wingston_agent_2",
            "state" => "active",
            "user" => %{},
            "label" => "@CUPZ_0x"
          },
          %{
            "agent" => "wingston_agent_3",
            "state" => "active",
            "user" => %{"name" => "Crypto Li"}
          },
          # no handle/label/name, no session id → nothing to seed → dropped
          %{"agent" => "wingston_agent_4", "state" => "active", "user" => %{}}
        ]
      }

      assert TopologyLive.agent_handles(snap) == %{
               # handle wins, raw (no "@" — it is a seed, not a display label)
               "wingston_agent_1" => "kongtouquan",
               "wingston_agent_2" => "@CUPZ_0x",
               "wingston_agent_3" => "Crypto Li"
             }
    end

    test "a session id alone (no handle) still seeds a distinct avatar off the cid" do
      snap = %{
        "sessions" => [
          %{
            "agent" => "wingston_agent_1",
            "session_id" => "telegram:222",
            "state" => "active",
            "user" => %{}
          }
        ]
      }

      assert TopologyLive.agent_handles(snap) == %{"wingston_agent_1" => "telegram:222"}
    end

    test "an ACTIVE session beats an idle leftover on a recycled slot" do
      snap = %{
        "sessions" => [
          %{
            "agent" => "wingston_agent_1",
            "session_id" => "telegram:new",
            "state" => "active",
            "user" => %{"handle" => "now"}
          },
          %{
            "agent" => "wingston_agent_1",
            "session_id" => "telegram:old",
            "state" => "idle",
            "user" => %{"handle" => "before"}
          }
        ]
      }

      assert TopologyLive.agent_handles(snap) == %{"wingston_agent_1" => "now"}
    end

    test "no sessions / no agents → empty map (canvas falls back to slot ids)" do
      assert TopologyLive.agent_handles(%{}) == %{}
      assert TopologyLive.agent_handles(%{"sessions" => [%{"user" => %{"handle" => "x"}}]}) == %{}
    end
  end

  describe "agent_sessions/1 (canvas click: slot => session id)" do
    alias SubzeroSwarmDashboardWeb.TopologyLive

    test "maps every slot to its session id — no display-label filter" do
      snap = %{
        "sessions" => [
          # label-less session: agent_handles drops it, agent_sessions MUST keep it
          %{
            "agent" => "wingston_agent_1",
            "session_id" => "tg:1:0",
            "state" => "idle",
            "user" => %{}
          },
          # recycled slot: active session wins the overwrite
          %{
            "agent" => "wingston_agent_2",
            "session_id" => "tg:2:0",
            "state" => "idle",
            "user" => %{}
          },
          %{
            "agent" => "wingston_agent_2",
            "session_id" => "tg:3:0",
            "state" => "active",
            "user" => %{}
          },
          # no slot → not in the map
          %{"agent" => nil, "session_id" => "tg:4:0", "state" => "idle", "user" => %{}}
        ]
      }

      assert TopologyLive.agent_sessions(snap) == %{
               "wingston_agent_1" => "tg:1:0",
               "wingston_agent_2" => "tg:3:0"
             }
    end

    test "empty snapshot → empty map" do
      assert TopologyLive.agent_sessions(%{}) == %{}
    end
  end
end
