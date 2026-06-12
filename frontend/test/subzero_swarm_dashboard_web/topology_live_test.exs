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
          activity: "waiting on browse"
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
    assert html =~ "waiting on browse"
    assert html =~ "12.4s"
    refute html =~ "feed unavailable"
  end
end
