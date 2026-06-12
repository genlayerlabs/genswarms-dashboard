defmodule SubzeroSwarmDashboardWeb.StoryPagesLiveTest do
  # Slice 6 of the live-events spec (§5.6): Sessions issue badges + audience
  # footer, Session detail REQUESTS, the Usage WINGSTON card.
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{EventsFeed, SwarmClientMock, RouterClientMock}

  setup :set_mox_global

  @cid "tg:1:0"
  @cid_dom Base.url_encode64("tg:1:0", padding: false)

  @snap %{
    "swarm" => "wingston",
    "status" => "running",
    "generated_at" => "2026-06-12T09:00:00Z",
    "summary" => %{
      "agents" => 1,
      "objects" => 6,
      "pool" => %{"size" => 2048, "leased" => 1, "idle" => 2047}
    },
    "sessions" => [
      %{
        "session_id" => "tg:1:0",
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-06-12T09:00:00Z",
        "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"}
      }
    ],
    "extensions" => %{},
    "warnings" => []
  }

  @kpis %{
    replies: 0,
    reply_p50: nil,
    reply_p95: nil,
    first_feedback_p50: nil,
    browse_ok: 0,
    browse_total: 0,
    asks: 0,
    compactions: 0,
    inbox_full: 0,
    failures: 0,
    stalled: 0,
    feed_gaps: 0
  }

  setup do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)

    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"session_id" => @cid, "turns" => [], "source" => "unavailable"}}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"logs" => [], "source" => "unavailable"}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
    end)

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    :ok
  end

  defp push_snap(view, snap \\ @snap) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    render(view)
  end

  # A {:story, summary} broadcast shaped exactly like EventsFeed.summary/1.
  defp push_story(view, overrides) do
    summary =
      %{
        in_flight: [],
        agents: [],
        kpis: Map.merge(@kpis, Map.get(overrides, :kpis, %{})),
        issues: [],
        story: [],
        feed_status: :ok,
        feed_age_s: 0,
        baseline_at: ~U[2026-06-12 09:12:00Z]
      }
      |> Map.merge(Map.delete(overrides, :kpis))

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:story, summary})
    render(view)
  end

  describe "sessions" do
    test "rows show an issue badge for a cid with a story issue, none without", %{conn: conn} do
      {:ok, view, _} = live(conn, "/sessions")
      push_snap(view)
      refute has_element?(view, "#session-issues-#{@cid_dom}")

      push_story(view, %{
        issues: [
          %{
            seq: 9,
            ts: 1.0,
            kind: "inbox_full",
            cid: @cid,
            agent: "wingston_agent_0",
            text: "⚠ rejected — inbox full",
            issue: true
          },
          %{seq: 8, ts: 0.5, kind: "reply_failed", cid: nil, agent: nil, text: "⚠", issue: true}
        ]
      })

      # exactly the cid's one issue on its row — the cid-less issue lands nowhere
      assert view |> element("#session-issues-#{@cid_dom}") |> render() =~ "⚠ 1"

      # the badge deep-links to the cid-filtered issues-only Events story view
      assert has_element?(
               view,
               ~s(a#session-issues-#{@cid_dom}[href="/events?cid=#{URI.encode_www_form(@cid)}&issues=1"])
             )
    end

    test "audience footer renders only when the snapshot publishes extensions.audience", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/sessions")
      push_snap(view)
      refute has_element?(view, "#audience-footer")

      snap =
        put_in(@snap, ["extensions", "audience"], %{
          "reachable_dms" => 214,
          "push_eligible" => 198
        })

      html = push_snap(view, snap)
      assert has_element?(view, "#audience-footer")
      # exactly the host's fields, keys humanized
      assert html =~ "reachable dms"
      assert html =~ "214"
      assert html =~ "push eligible"
      assert html =~ "198"
    end
  end

  describe "session detail REQUESTS" do
    test "renders this cid's episodes from the feed, newest first chain", %{conn: conn} do
      stub(SwarmClientMock, :events_feed, fn "wingston", since, _limit ->
        case since do
          0 ->
            {:ok, %{"events" => [], "seq" => 10, "source" => "feed"}}

          10 ->
            {:ok,
             %{
               "events" => [
                 %{"seq" => 11, "ts" => 100.0, "kind" => "request_open", "cid" => @cid},
                 %{
                   "seq" => 12,
                   "ts" => 101.0,
                   "kind" => "routed",
                   "cid" => @cid,
                   "slot" => "wingston_agent_0"
                 },
                 %{
                   "seq" => 13,
                   "ts" => 109.0,
                   "kind" => "reply_sent",
                   "cid" => @cid,
                   "ok" => true
                 }
               ],
               "seq" => 13,
               "source" => "feed"
             }}

          _ ->
            {:ok, %{"events" => [], "seq" => 13, "source" => "feed"}}
        end
      end)

      feed = start_supervised!(EventsFeed)
      # first poll baselines at seq 10, the manual second poll folds the episode
      _ = :sys.get_state(feed)
      send(feed, :poll)
      _ = :sys.get_state(feed)

      {:ok, view, _} = live(conn, "/sessions/#{@cid}")
      html = render(view)

      assert has_element?(view, "#session-requests")
      assert has_element?(view, "#session-request-0")
      refute has_element?(view, "#session-requests-empty")
      assert html =~ "claim 1.0s"
      assert html =~ "replied 9.0s"
      assert html =~ "requests observed since"
    end

    test "shows the explicit empty state (same honesty label) when nothing was observed", %{
      conn: conn
    } do
      # the EventsFeed process isn't running at all (test default) — same face
      # as an empty feed
      {:ok, view, _} = live(conn, "/sessions/#{@cid}")
      html = render(view)

      assert has_element?(view, "#session-requests")
      assert has_element?(view, "#session-requests-empty")
      assert html =~ "requests observed since"
    end
  end

  describe "usage WINGSTON card" do
    test "renders the bot counters from the story, labeled since-baseline", %{conn: conn} do
      {:ok, view, _} = live(conn, "/usage")
      refute has_element?(view, "#wingston-usage")

      html =
        push_story(view, %{
          kpis: %{replies: 41, browse_ok: 21, browse_total: 25, asks: 7, compactions: 3}
        })

      assert has_element?(view, "#wingston-usage")
      assert html =~ "Replies"
      assert html =~ "41"
      # 21/25 ok
      assert html =~ "84%"
      assert html =~ "since 09:12"
    end

    test "prefers durable extensions.metrics_today values, labeled today", %{conn: conn} do
      {:ok, view, _} = live(conn, "/usage")

      snap = put_in(@snap, ["extensions", "metrics_today"], %{"replies" => 120})
      push_snap(view, snap)
      html = push_story(view, %{kpis: %{replies: 41}})

      assert has_element?(view, "#wingston-usage")
      assert html =~ "120"
      assert html =~ "today"
      refute html =~ ">41<"
    end
  end
end
