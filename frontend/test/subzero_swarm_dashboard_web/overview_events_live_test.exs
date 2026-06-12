defmodule SubzeroSwarmDashboardWeb.OverviewEventsLiveTest do
  # Slice 5 of the live-events spec (§5.6): Overview story panels (in-flight /
  # agents / KPI / issues + degraded line) and the story-first Events page
  # (raw toggle, URL filters, live stream, pause pill).
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{SwarmClientMock, RouterClientMock}

  setup :set_mox_global

  @cid "tg:1:0"
  @cid_path Base.url_encode64("tg:1:0", padding: false)

  @snap %{
    "swarm" => "wingston",
    "status" => "running",
    "uptime_s" => 5821,
    "data_source" => "in_process",
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
        "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"},
        "user" => %{"handle" => "albert", "name" => "Albert"}
      }
    ],
    "extensions" => %{},
    "warnings" => []
  }

  @kpis %{
    replies: 41,
    reply_p50: 9.2,
    reply_p95: 51.0,
    first_feedback_p50: 3.1,
    browse_ok: 21,
    browse_total: 25,
    asks: 5,
    compactions: 3,
    inbox_full: 1,
    failures: 0,
    stalled: 0,
    feed_gaps: 0
  }

  setup do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)
    stub(SwarmClientMock, :events, fn _, _ -> {:ok, []} end)

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
  defp push_story(view, overrides \\ %{}) do
    summary =
      Map.merge(
        %{
          in_flight: [],
          agents: [],
          kpis: @kpis,
          issues: [],
          story: [],
          feed_status: :ok,
          feed_age_s: 0,
          baseline_at: ~U[2026-06-12 09:12:00Z]
        },
        Map.new(overrides)
      )

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:story, summary})
    render(view)
  end

  # A story-ring row exactly as Story.Reducer builds them.
  defp row(seq, over \\ %{}) do
    Map.merge(
      %{
        seq: seq,
        ts: 1_000.0 + seq,
        kind: "request_open",
        cid: @cid,
        agent: nil,
        text: "▶ @1 request open",
        issue: false
      },
      Map.new(over)
    )
  end

  describe "overview story panels" do
    test "renders in-flight rows from a story tick", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      push_snap(view)

      html =
        push_story(view,
          in_flight: [
            %{
              cid: @cid,
              user: "1",
              agent: "wingston_agent_0",
              count: 2,
              opened_at: 100.0,
              elapsed_s: 12.4,
              stalled: false,
              activity: "waiting on browse"
            }
          ],
          agents: [
            %{
              name: "wingston_agent_0",
              state: :waiting,
              wait_on: "browse",
              queue: 0,
              since: 100.0,
              elapsed_s: 12.4
            }
          ]
        )

      assert has_element?(view, "#in-flight-panel")
      assert has_element?(view, "#in-flight-tg-1-0")
      assert html =~ "waiting on browse"
      assert html =~ "12.4s"
      # the snapshot join upgrades the cid's chat part to the real @handle
      assert html =~ "@albert"
      # each row deep-links to its session (cid base64-encoded like SessionsLive)
      assert has_element?(view, ~s(#in-flight-tg-1-0 a[href="/sessions/#{@cid_path}"]))
      # the agents strip reflects the slot state
      assert has_element?(view, "#agents-strip")
      assert html =~ "waiting browse"
      assert html =~ "pool 1/2048 leased"
    end

    test "collapses to the idle one-liner when nothing is in flight", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      html =
        push_story(view,
          story: [
            %{
              seq: 13,
              ts: 1_009.0,
              kind: "reply_sent",
              cid: @cid,
              agent: nil,
              text: "✓ @1 replied in 9.0s",
              issue: false
            }
          ]
        )

      assert has_element?(view, "#in-flight-idle")
      assert html =~ "nobody waiting"
      assert html =~ "replied in 9.0s at"
    end

    test "labels the KPI window with the story baseline, today only via metrics_today", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/")
      html = push_story(view)

      assert has_element?(view, "#kpi-window-label")
      # baseline rendered through <.local_time> (browser-local via hook; UTC fallback text)
      assert has_element?(view, "#kpi-since", "09:12")
      assert html =~ "9.2s"
      # 21/25 browse ok
      assert html =~ "84% ok"
      refute html =~ "today"

      # the durable overlay upgrades exactly the counters the host published
      snap = put_in(@snap, ["extensions", "metrics_today"], %{"replies" => 120})
      push_snap(view, snap)
      html = render(view)
      assert html =~ "120"
      assert html =~ "today"
    end

    test "issue rows deep-link to the filtered events page", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      html =
        push_story(view,
          issues: [
            %{
              seq: nil,
              ts: 1_200.0,
              kind: "stalled",
              cid: @cid,
              agent: "wingston_agent_0",
              text: "⚠ stalled — no reply in 200.0s",
              issue: true
            }
          ]
        )

      assert has_element?(view, "#issues-panel")
      assert has_element?(view, "#issue-0")
      assert html =~ "stalled — no reply"
      assert html =~ "issues=1"
    end

    test "degrades to the one-line explainer when the feed is down, snapshot cards keep working",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      push_snap(view)
      push_story(view, feed_status: :unavailable)

      assert has_element?(view, "#story-degraded")
      refute has_element?(view, "#in-flight-panel")
      refute has_element?(view, "#kpi-panel")
      # snapshot-driven cards are unaffected
      assert render(view) =~ "2048"
    end
  end

  describe "events view toggle + URL filters" do
    test "defaults to the story view; the toggle patches to engine raw and back", %{conn: conn} do
      {:ok, view, _} = live(conn, "/events")
      assert has_element?(view, "#story-rows")
      refute has_element?(view, "#raw-filter-form")

      view |> element("#events-view-raw") |> render_click()
      assert_patch(view, "/events?view=raw")
      assert has_element?(view, "#raw-filter-form")
      refute has_element?(view, "#story-rows")

      view |> element("#events-view-story") |> render_click()
      assert_patch(view)
      assert has_element?(view, "#story-rows")
    end

    test "URL params restore the story filters (the Overview/Sessions deep-link target)", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/events?cid=tg:9:0&issues=1&kind=reply_sent")

      assert has_element?(view, ~s(#story-filter-form input[name="cid"][value="tg:9:0"]))
      assert has_element?(view, ~s(#story-filter-form input[name="issues"][checked]))

      assert has_element?(
               view,
               ~s(#story-filter-form select[name="kind"] option[value="reply_sent"][selected])
             )
    end

    test "view=raw in the URL restores the raw view", %{conn: conn} do
      {:ok, view, _} = live(conn, "/events?view=raw")
      assert has_element?(view, "#raw-filter-form")
      refute has_element?(view, "#story-rows")
    end

    test "the user dropdown is built from the snapshot's session handles", %{conn: conn} do
      {:ok, view, _} = live(conn, "/events")
      push_snap(view)

      assert has_element?(view, ~s(#story-user-select option[value="tg:1:0"]))
      assert render(view) =~ "@albert"
    end
  end

  describe "events story stream" do
    test "story ticks prepend rows, honoring the cid filter; rows link to the session", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/events?cid=tg:1:0")

      push_story(view, story: [row(12, cid: "tg:2:0"), row(11)])

      assert has_element?(view, "#story-row-11")
      refute has_element?(view, "#story-row-12")
      assert has_element?(view, ~s(#story-row-11 a[href="/sessions/#{@cid_path}"]))
    end

    test "pause buffers incoming rows (+N new); resume prepends the buffer", %{conn: conn} do
      {:ok, view, _} = live(conn, "/events")

      push_story(view, story: [row(1)])
      assert has_element?(view, "#story-row-1")

      view |> element("#events-pause") |> render_click()

      push_story(view, story: [row(2), row(1)])
      push_story(view, story: [row(3), row(2), row(1)])

      assert render(view) =~ "+2 new"
      refute has_element?(view, "#story-row-2")
      refute has_element?(view, "#story-row-3")

      view |> element("#events-pause") |> render_click()
      assert has_element?(view, "#story-row-2")
      assert has_element?(view, "#story-row-3")
      refute render(view) =~ "+2 new"
    end
  end
end
