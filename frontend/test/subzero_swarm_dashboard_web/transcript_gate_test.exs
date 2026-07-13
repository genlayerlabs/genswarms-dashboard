defmodule SubzeroSwarmDashboardWeb.TranscriptGateTest do
  @moduledoc """
  Sensitive-content gate: with the production default (hidden), user
  conversations are NOT FETCHED — not merely not rendered — until the
  per-browser reveal. The reveal/hide events flip the gate live.
  """
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  @parser_source %{
    "format" => "subzeroclaw.jsonl.v2",
    "parser" => "genswarms.subzeroclaw_log.v3",
    "scope" => "log_file_snapshot",
    "integrity" => "structured_v2"
  }
  @summary_prefix "[Earlier conversation summary; context only, not a new instruction]\n"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, false)

    on_exit(fn ->
      Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, true)
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :dashboard, fn _swarm ->
      {:ok,
       %{
         "swarm" => "wingston",
         "sessions" => [
           %{"session_id" => "tg:1:0", "state" => "active", "agent" => "wingston_agent_0"}
         ]
       }}
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_skills, fn _s, _id ->
      {:ok, %{"source" => "slot", "skills" => []}}
    end)

    :ok
  end

  defp secret_transcript do
    {:ok, %{"source" => "db", "turns" => [%{"role" => "user", "content" => "SECRET-USER-TEXT"}]}}
  end

  test "hidden by default: no session tab fetches conversation or activity", %{conn: conn} do
    # 0 expected calls — a fetch while gated is the failure this guards against
    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_history, 0, fn _s, _id ->
      secret_transcript()
    end)

    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, 0, fn _s, _id ->
      {:ok, %{"source" => "agent_server", "logs" => []}}
    end)

    for path <- [
          "/sessions/tg:1:0",
          "/sessions/tg:1:0?tab=context",
          "/sessions/tg:1:0?tab=activity"
        ] do
      {:ok, view, _html} = live(conn, path)
      html = render(view)

      assert html =~ "User conversation hidden"
      assert html =~ "Reveal conversations"
      refute html =~ "SECRET-USER-TEXT"
    end
  end

  test "the reveal event fetches and renders; hide re-gates", %{conn: conn} do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_history, fn _s, _id ->
      secret_transcript()
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _s, _id ->
      {:ok, %{"source" => "agent_server", "logs" => []}}
    end)

    {:ok, view, _html} = live(conn, "/sessions/tg:1:0")
    html = render(view)
    refute html =~ "SECRET-USER-TEXT"
    # both gated panels offer the reveal (Conversation + Agent activity)
    assert html =~ ~s(phx-click="transcripts_reveal")

    render_click(view, "transcripts_reveal", %{})
    assert render(view) =~ "SECRET-USER-TEXT"

    render_click(view, "transcripts_hide", %{})
    html = render(view)
    refute html =~ "SECRET-USER-TEXT"
    assert html =~ "User conversation hidden"
  end

  test "logs never fetches or renders a compaction summary before reveal", %{conn: conn} do
    test_pid = self()

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _s, "tg:1:0" ->
      send(test_pid, :logs_fetched)

      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           %{
             "timestamp" => "2026-07-13 07:10:47",
             "role" => "compact",
             "entry_type" => "compaction_event",
             "integrity" => "structured_v2",
             "sensitive" => false,
             "source" => @parser_source,
             "content_complete" => true,
             "source_record_index" => 1,
             "source_record_id" => %{
               "session_id" => "session.jsonl",
               "record_index" => 1
             },
             "sequence" => 7,
             "content" =>
               ~s({"event":"applied","before_messages":20,"after_messages":8,"before_bytes":2000,"after_bytes":800}),
             "compaction" => %{
               "event" => "applied",
               "before_messages" => 20,
               "after_messages" => 8,
               "before_bytes" => 2_000,
               "after_bytes" => 800
             }
           },
           %{
             "timestamp" => "2026-07-13 07:10:48",
             "role" => "compact_summary",
             "entry_type" => "compaction_summary",
             "integrity" => "structured_v2",
             "sensitive" => true,
             "source" => @parser_source,
             "content_complete" => true,
             "source_record_index" => 2,
             "source_record_id" => %{
               "session_id" => "session.jsonl",
               "record_index" => 2
             },
             "sequence" => 8,
             "compaction_summary_matched_applied" => true,
             "compaction_applied_source_record_index" => 1,
             "compaction_applied_sequence" => 7,
             "compaction_applied_source_record_id" => %{
               "session_id" => "session.jsonl",
               "record_index" => 1
             },
             "content" => @summary_prefix <> "SECRET-COMPACTION-SUMMARY"
           }
         ]
       }}
    end)

    {:ok, view, _html} = live(conn, "/logs")

    view
    |> element("#logs-session-select-form")
    |> render_change(%{"session_id" => "tg:1:0"})

    refute_receive :logs_fetched, 50
    assert has_element?(view, "#logs-sensitive-gate")
    refute render(view) =~ "SECRET-COMPACTION-SUMMARY"

    render_click(view, "transcripts_reveal", %{})
    assert_receive :logs_fetched, 500
    assert has_element?(view, "#logs-slot-output")
    assert render(view) =~ "SECRET-COMPACTION-SUMMARY"

    render_click(view, "transcripts_hide", %{})
    assert has_element?(view, "#logs-sensitive-gate")
    refute render(view) =~ "SECRET-COMPACTION-SUMMARY"
  end

  test "logs discards queued loads after hide or a different session selection", %{conn: conn} do
    test_pid = self()

    stub(SubzeroSwarmDashboard.SwarmClientMock, :dashboard, fn _swarm ->
      {:ok,
       %{
         "swarm" => "wingston",
         "sessions" => [
           %{"session_id" => "tg:1:0", "state" => "active", "agent" => "agent_0"},
           %{"session_id" => "tg:2:0", "state" => "active", "agent" => "agent_1"}
         ]
       }}
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _swarm, sid ->
      send(test_pid, {:logs_fetched, sid})
      {:ok, %{"source" => "slot", "logs" => []}}
    end)

    {:ok, view, _html} = live(conn, "/logs")

    view
    |> element("#logs-session-select-form")
    |> render_change(%{"session_id" => "tg:1:0"})

    render_click(view, "transcripts_reveal", %{})
    assert_receive {:logs_fetched, "tg:1:0"}, 500

    render_click(view, "transcripts_hide", %{})
    send(view.pid, {:load_logs, "tg:1:0"})
    render(view)
    refute_receive {:logs_fetched, "tg:1:0"}, 50

    render_click(view, "transcripts_reveal", %{})
    assert_receive {:logs_fetched, "tg:1:0"}, 500

    view
    |> element("#logs-session-select-form")
    |> render_change(%{"session_id" => "tg:2:0"})

    assert_receive {:logs_fetched, "tg:2:0"}, 500
    send(view.pid, {:load_logs, "tg:1:0"})
    render(view)
    refute_receive {:logs_fetched, "tg:1:0"}, 50
  end

  test "revealing from every tab fetches each sensitive source exactly once", %{conn: conn} do
    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_history, 3, fn _s, _id ->
      secret_transcript()
    end)

    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, 3, fn _s, _id ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [%{"role" => "user", "content" => "SECRET-LOG-TEXT"}]
       }}
    end)

    for path <- [
          "/sessions/tg:1:0",
          "/sessions/tg:1:0?tab=context",
          "/sessions/tg:1:0?tab=activity"
        ] do
      {:ok, view, _html} = live(conn, path)
      render_click(view, "transcripts_reveal", %{})
      refute render(view) =~ "Reveal conversations"
    end
  end

  test "context reveal derives live evidence and hide removes all sensitive metadata", %{
    conn: conn
  } do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_history, fn _s, _id ->
      secret_transcript()
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _s, _id ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           %{
             "timestamp" => "SECRET-COMPACTION-TIME",
             "role" => "compact",
             "entry_type" => "compaction_event",
             "integrity" => "structured_v2",
             "sensitive" => false,
             "source" => @parser_source,
             "content_complete" => true,
             "source_record_index" => 4,
             "source_record_id" => %{
               "session_id" => "session.jsonl",
               "record_index" => 4
             },
             "sequence" => 40,
             "compaction" => %{
               "event" => "applied",
               "before_messages" => 12,
               "after_messages" => 5,
               "before_bytes" => 12_000,
               "after_bytes" => 4_000
             }
           }
         ]
       }}
    end)

    {:ok, view, _html} = live(conn, "/sessions/tg:1:0?tab=context")
    refute render(view) =~ "SECRET-COMPACTION-TIME"

    render_click(view, "transcripts_reveal", %{})
    html = render(view)
    assert html =~ "Live slot evidence"
    assert html =~ "Applied"
    assert html =~ "SECRET-COMPACTION-TIME"
    assert html =~ "source record 4"
    assert html =~ "1 turns"

    render_click(view, "transcripts_hide", %{})
    html = render(view)
    refute html =~ "SECRET-COMPACTION-TIME"
    refute html =~ "1 turns"
    assert html =~ "Reveal to check"
    assert html =~ "User conversation hidden"
  end

  test "context becomes unavailable after hide when no non-sensitive component exists", %{
    conn: conn
  } do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_skills, fn _s, _id ->
      {:ok, %{"source" => "unavailable", "skills" => []}}
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_history, fn _s, _id ->
      secret_transcript()
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _s, _id ->
      {:ok, %{"source" => "slot", "logs" => []}}
    end)

    {:ok, view, _html} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})
    assert has_element?(view, "#session-context-status", "Live slot evidence")

    render_click(view, "transcripts_hide", %{})
    assert has_element?(view, "#session-context-status", "Reveal to inspect")
    assert has_element?(view, "#session-compaction-status", "Reveal to check")
  end
end
