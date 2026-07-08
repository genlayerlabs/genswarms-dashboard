defmodule SubzeroSwarmDashboardWeb.TopologyLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "mounts the pipeline hook el (unique id + phx-update=ignore) and pushes the layout", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/topology")

    assert has_element?(view, ~s(#pipeline[phx-hook="Pipeline"][phx-update="ignore"]))
    refute has_element?(view, ~s(#pipeline[data-debug]))
    assert_push_event(view, "pipeline:init", %{nodes: [_ | _], chatter: [_ | _]})
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

  test "pipeline:agents carries pool slots only (agent_pattern filters samples)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/topology")

    snap = %{
      "nodes" => [
        %{"type" => "agent", "name" => "wingston_agent_0"},
        %{"type" => "agent", "name" => "conversation_sample"},
        %{"type" => "object", "name" => "ingress"}
      ]
    }

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})

    assert_push_event(view, "pipeline:agents", %{agents: ["wingston_agent_0"]})
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
          %{"agent" => "wingston_agent_2", "state" => "active", "user" => %{}, "label" => "@CUPZ_0x"},
          %{"agent" => "wingston_agent_3", "state" => "active", "user" => %{"name" => "Crypto Li"}},
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
          %{"agent" => "wingston_agent_1", "session_id" => "telegram:222", "state" => "active", "user" => %{}}
        ]
      }

      assert TopologyLive.agent_handles(snap) == %{"wingston_agent_1" => "telegram:222"}
    end

    test "an ACTIVE session beats an idle leftover on a recycled slot" do
      snap = %{
        "sessions" => [
          %{"agent" => "wingston_agent_1", "session_id" => "telegram:new", "state" => "active", "user" => %{"handle" => "now"}},
          %{"agent" => "wingston_agent_1", "session_id" => "telegram:old", "state" => "idle", "user" => %{"handle" => "before"}}
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
          %{"agent" => "wingston_agent_1", "session_id" => "tg:1:0", "state" => "idle", "user" => %{}},
          # recycled slot: active session wins the overwrite
          %{"agent" => "wingston_agent_2", "session_id" => "tg:2:0", "state" => "idle", "user" => %{}},
          %{"agent" => "wingston_agent_2", "session_id" => "tg:3:0", "state" => "active", "user" => %{}},
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
