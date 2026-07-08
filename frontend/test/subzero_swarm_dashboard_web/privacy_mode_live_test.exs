defmodule SubzeroSwarmDashboardWeb.PrivacyModeLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{RouterClientMock, SwarmClientMock}

  setup :set_mox_global

  @canary_handle "canary_h4ndle"
  @canary_name "Canary Q. Name"
  @canary_cid "tg:987654321:0"
  @canary_cid_encoded Base.url_encode64(@canary_cid, padding: false)
  @canary_chat_id "987654321"
  @canary_text "CANARY-TEXT"

  @canary_snap %{
    "swarm" => "wingston",
    "dashboard_title" => "Wingston",
    "status" => "running",
    "generated_at" => "2026-07-08T12:00:00Z",
    "summary" => %{
      "agents" => 1,
      "objects" => 2,
      "pool" => %{"size" => 4, "leased" => 1, "idle" => 3}
    },
    "nodes" => [
      %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
      %{
        "name" => "wingston_agent_0",
        "type" => "agent",
        "state" => "active",
        "session_id" => @canary_cid
      }
    ],
    "edges" => [%{"from" => "ingress", "to" => "wingston_agent_0"}],
    "sessions" => [
      %{
        "session_id" => @canary_cid,
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-07-08T12:00:00Z",
        "transport_ref" => %{"chat_id" => @canary_chat_id, "thread_id" => "0"},
        "metadata" => %{"chat_type" => "dm"},
        "user" => %{"handle" => @canary_handle, "name" => @canary_name}
      }
    ],
    "extensions" => %{
      "consumers" => %{
        "count" => 1,
        "items" => [%{"session_id" => @canary_cid, "mode" => "scout", "opt_out" => false}]
      }
    },
    "warnings" => []
  }

  setup do
    parent = self()

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @canary_snap} end)

    stub(SwarmClientMock, :session_history, fn _, @canary_cid ->
      send(parent, {:history_loaded, @canary_cid})

      {:ok,
       %{
         "session_id" => @canary_cid,
         "source" => "store",
         "turns" => [
           %{"role" => "user", "content" => @canary_text, "at" => 1_782_000_000},
           %{"role" => "assistant", "content" => "reply #{@canary_text}", "at" => 1_782_000_060}
         ]
       }}
    end)

    stub(SwarmClientMock, :session_logs, fn _, @canary_cid ->
      send(parent, {:logs_loaded, @canary_cid})

      {:ok,
       %{
         "source" => "agent_server",
         "logs" => [
           %{"timestamp" => "2026-07-08T12:00:00Z", "role" => "user", "content" => @canary_text}
         ]
       }}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
    end)

    :ok
  end

  defp push_canary_snap(view) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, @canary_snap})
    render(view)
  end

  defp push_canary_story(view) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {
      :story,
      %{
        feed_status: :ok,
        feed_age_s: 0,
        baseline_at: ~U[2026-07-08 12:00:00Z],
        in_flight: [
          %{
            cid: @canary_cid,
            user: @canary_handle,
            agent: "wingston_agent_0",
            count: 1,
            opened_at: 1.0,
            elapsed_s: 3.5,
            stalled: false,
            activity: "thinking"
          }
        ],
        agents: [],
        kpis: %{},
        issues: [],
        story: []
      }
    })

    render(view)
  end

  defp refute_canary(html) do
    refute html =~ @canary_handle
    refute html =~ @canary_name
    refute html =~ @canary_cid
    refute html =~ @canary_cid_encoded
    refute html =~ @canary_chat_id
    refute html =~ @canary_text
  end

  defp assert_canary_identity(html) do
    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_cid
  end

  test "overview receives privacy from the session and renders the active chrome", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-privacy="on")
    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(id="privacy-badge")
    assert html =~ ~r/<span id="privacy-badge"[^>]*>\s*privacy\s*<\/span>/
    assert html =~ "hero-eye-slash"
  end

  test "privacy badge is absent when privacy is off", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-privacy="off")
    assert html =~ ~s(aria-pressed="false")
    assert html =~ "hero-eye"
    refute html =~ ~s(id="privacy-badge")
  end

  test "topology privacy masks ids and hashes avatar seeds while preserving canvas targets", %{
    conn: conn
  } do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, ~p"/topology?debug=1")

    _html = push_canary_snap(view)
    assert_push_event(view, "pipeline:agents", payload)

    expected_seed = :crypto.hash(:sha256, @canary_handle) |> Base.encode16(case: :lower)
    assert payload.handles["wingston_agent_0"] == expected_seed
    assert payload.sessions["wingston_agent_0"] == "inspect:0"
    assert payload.session_labels["wingston_agent_0"] == "tg:•••"
    refute inspect(payload) =~ @canary_handle
    refute inspect(payload) =~ @canary_cid

    html = push_canary_story(view)
    refute_canary(html)
    assert html =~ "•••"
    assert html =~ "thinking"
    assert html =~ "3.5s"

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {
      :display_event,
      %{
        "kind" => "routed",
        "cid" => @canary_cid,
        "slot" => "wingston_agent_0",
        "text" => @canary_text
      }
    })

    assert_push_event(view, "pipeline:event", event)
    refute inspect(event) =~ @canary_cid
    refute inspect(event) =~ @canary_text
    assert event["cid"] =~ "cid:"
    assert event["text"] == "▪▪▪▪▪"
  end

  test "topology privacy off keeps existing identity output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = push_canary_snap(view)
    assert_push_event(view, "pipeline:agents", payload)

    assert payload.handles["wingston_agent_0"] == @canary_handle
    assert payload.sessions["wingston_agent_0"] == @canary_cid
    assert_canary_identity(html)
  end

  test "sessions privacy masks row identity and shared inspector transcripts", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = push_canary_snap(view)
    refute_canary(html)
    assert html =~ "•••"
    assert html =~ "wingston_agent_0"
    assert html =~ "scout"

    view |> element(~s(tr[phx-value-session_id="inspect:0"])) |> render_click()
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    refute_canary(html)
    assert html =~ "▪▪▪▪▪"
    assert html =~ "Conversation"
  end

  test "sessions privacy off keeps row identity and inspector transcript output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = push_canary_snap(view)
    assert_canary_identity(html)

    view |> element(~s(tr[phx-value-session_id="#{@canary_cid}"])) |> render_click()
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    assert html =~ @canary_text
    assert_canary_identity(html)
  end

  test "session detail privacy masks header ids and conversation text", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/sessions/#{@canary_cid_encoded}")

    _html = push_canary_snap(view)
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    refute_canary(html)
    assert html =~ "▪▪▪▪▪"
    assert html =~ "wingston_agent_0"
    assert html =~ "telegram"
  end

  test "session detail privacy off keeps existing identity and transcript output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/sessions/#{@canary_cid_encoded}")

    _html = push_canary_snap(view)
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    assert_canary_identity(html)
    assert html =~ @canary_text
    assert html =~ @canary_chat_id
  end
end
