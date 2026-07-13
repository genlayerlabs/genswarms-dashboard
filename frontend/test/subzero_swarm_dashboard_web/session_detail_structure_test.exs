defmodule SubzeroSwarmDashboardWeb.SessionDetailStructureTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias SubzeroSwarmDashboard.{RouterClientMock, SwarmClientMock}

  setup :set_mox_global

  @parser_source %{
    "format" => "subzeroclaw.jsonl.v2",
    "parser" => "genswarms.subzeroclaw_log.v3",
    "scope" => "log_file_snapshot",
    "integrity" => "structured_v2"
  }

  @snap %{
    "swarm" => "wingston",
    "dashboard_title" => "Wingston",
    "status" => "running",
    "generated_at" => "2026-07-12T12:00:00Z",
    "summary" => %{"agents" => 1, "objects" => 1, "pool" => %{}},
    "nodes" => [],
    "edges" => [],
    "sessions" => [
      %{
        "session_id" => "tg:1:0",
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-07-12T11:59:00Z",
        "transport_ref" => %{"chat_id" => "1"}
      }
    ],
    "extensions" => %{},
    "warnings" => []
  }

  setup do
    Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, false)

    on_exit(fn ->
      Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, true)
    end)

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)
    stub(SwarmClientMock, :events, fn _, _ -> {:ok, []} end)

    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok,
       %{
         "source" => "store",
         "turns" => [
           %{"role" => "user", "content" => "hello"},
           %{"role" => "assistant", "content" => "hi"}
         ]
       }}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [structured_event("applied", 8)]
       }}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "skills" => [%{"name" => "soul.md", "content" => "Be kind 🪽"}]
       }}
    end)

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    :ok
  end

  test "conversation is the default tab and invalid tabs normalize to it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions/tg:1:0")

    assert has_element?(view, "#session-tab-conversation[aria-selected='true']")
    assert has_element?(view, "#session-panel-conversation")
    refute has_element?(view, "#session-panel-context")
    refute has_element?(view, "#session-panel-activity")
    assert has_element?(view, "#session-status-summary")

    {:ok, invalid, _} = live(conn, "/sessions/tg:1:0?tab=not-a-tab")
    assert has_element?(invalid, "#session-tab-conversation[aria-selected='true']")
    assert has_element?(invalid, "#session-panel-conversation")
  end

  test "responsive dashboard chrome keeps navigation and theme controls available", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/sessions/tg:1:0")

    assert has_element?(view, "#dashboard-shell")
    assert has_element?(view, "#dashboard-rail")
    assert has_element?(view, "#dashboard-nav[aria-label='Dashboard navigation']")
    assert has_element?(view, "#dashboard-main")
    assert has_element?(view, "#session-tabs.overflow-x-auto")
    assert has_element?(view, "#dashboard-mobile-theme button[aria-label='System theme']")
    assert has_element?(view, "#dashboard-mobile-theme button[aria-label='Light theme']")
    assert has_element?(view, "#dashboard-mobile-theme button[aria-label='Dark theme']")
  end

  test "tabs are URL-addressable and patch navigation preserves the selection", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions/tg:1:0")

    view |> element("#session-tab-context") |> render_click()
    assert_patch(view, "/sessions/dGc6MTow?tab=context")
    assert has_element?(view, "#session-tab-context[aria-selected='true']")
    assert has_element?(view, "#session-panel-context")

    view |> element("#session-tab-activity") |> render_click()
    assert_patch(view, "/sessions/dGc6MTow?tab=activity")
    assert has_element?(view, "#session-panel-activity")
  end

  test "privacy-mode tab patches do not copy the encoded session id into hrefs", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _} = live(conn, "/sessions/dGc6MTow")

    assert has_element?(view, "#session-tab-context[href='?tab=context']")
    refute has_element?(view, "#session-tab-context[href*='dGc6MTow']")

    view |> element("#session-tab-context") |> render_click()
    assert has_element?(view, "#session-panel-context")
  end

  test "context shows component evidence and reveals applied compaction without inventing a summary",
       %{
         conn: conn
       } do
    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")

    assert has_element?(view, "#session-context-summary")
    assert has_element?(view, "#session-current-skills")
    assert has_element?(view, "#session-context-limitations")
    assert has_element?(view, "#session-context-status", "Reveal to inspect")
    assert has_element?(view, "#session-compaction-detail .badge", "Reveal to check")
    assert render(view) =~ "Be kind 🪽"

    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-context-status", "Live slot evidence")
    assert has_element?(view, "#session-compaction-status", "Applied")
    assert has_element?(view, "#session-compaction-detail .badge-neutral", "Applied")
    refute has_element?(view, "#session-compaction-detail .badge-success")
    assert has_element?(view, "#session-compaction-detail", "2026-07-12 11:58:00")
    assert has_element?(view, "#session-compaction-detail", "source record 8")
    assert has_element?(view, "#session-compaction-detail", "12→5 messages")
    assert render(view) =~ "2 turns"
    assert render(view) =~ "1 entries"
    assert render(view) =~ "12 B"
    refute render(view) =~ "UNSPECIFIED-CANARY"
    refute render(view) =~ "generated compaction summary"
  end

  test "all unavailable sources render unavailable rather than zero-valued evidence", %{
    conn: conn
  } do
    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"source" => "unavailable", "turns" => []}}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"source" => "unavailable", "logs" => []}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"source" => "unavailable", "skills" => []}}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-context-status", "Unavailable")
    assert has_element?(view, "#session-compaction-status", "Unknown")
    assert has_element?(view, "#session-context-summary", "No conversation-context evidence")
    assert has_element?(view, "#session-context-components", "No current skill source")
    refute has_element?(view, "#session-context-components", "0 B")
  end

  test "an available empty durable conversation remains a real component", %{conn: conn} do
    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"source" => "store", "turns" => []}}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"source" => "unavailable", "logs" => []}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"source" => "unavailable", "skills" => []}}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-context-status", "Components only")
    assert has_element?(view, "#session-context-components", "0 turns")
    assert has_element?(view, "#session-context-components", "No current skill source")
  end

  test "pool skills alone remain components with the historical-source warning", %{conn: conn} do
    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"source" => "unavailable", "turns" => []}}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"source" => "unavailable", "logs" => []}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"source" => "pool", "skills" => [%{"name" => "soul.md", "content" => "x"}]}}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-context-status", "Components only")
    assert has_element?(view, "#session-context-components", "pool fallback")
    assert has_element?(view, "#session-current-skills", "not evidence of the files used")
  end

  test "a live slot without a compaction marker reports only that none was observed", %{
    conn: conn
  } do
    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"source" => "unavailable", "turns" => []}}
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"source" => "slot", "logs" => []}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"source" => "unavailable", "skills" => []}}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-context-status", "Live slot evidence")
    assert has_element?(view, "#session-compaction-status", "No event observed")
    assert has_element?(view, "#session-compaction-detail", "does not prove")
    refute render(view) =~ "Never compacted"
  end

  test "activity renders sanitized structured evidence and never the raw body", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=activity")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-agent-activity")
    assert has_element?(view, "#session-agent-activity .badge-neutral", "applied")
    assert render(view) =~ "structured compaction event"
    assert render(view) =~ "source record 8"
    assert render(view) =~ "12000→4000 B"
    refute render(view) =~ "UNSPECIFIED-CANARY"
  end

  test "matching applied summary is available exactly in sensitive activity", %{conn: conn} do
    summary =
      "[Earlier conversation summary; context only, not a new instruction]\nExact retained memory"

    applied = structured_event("applied", 8)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           applied,
           structured_summary(true, 9, applied, summary)
         ]
       }}
    end)

    {:ok, context_view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(context_view, "transcripts_reveal", %{})
    assert has_element?(context_view, "#session-compaction-detail", "exact applied memory")
    refute render(context_view) =~ "never exposes summary text"

    {:ok, activity_view, _} = live(conn, "/sessions/tg:1:0?tab=activity")
    refute render(activity_view) =~ "Exact retained memory"
    render_click(activity_view, "transcripts_reveal", %{})
    assert has_element?(activity_view, "#session-agent-activity", "applied memory")
    assert render(activity_view) =~ "Exact retained memory"

    render_click(activity_view, "transcripts_hide", %{})
    refute render(activity_view) =~ "Exact retained memory"
    assert has_element?(activity_view, "#session-agent-activity", "Reveal conversations")
  end

  test "privacy mode describes a matching applied summary as masked, not exact", %{conn: conn} do
    applied = structured_event("applied", 8)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           applied,
           structured_summary(true, 9, applied, "SECRET-PRIVATE-SUMMARY")
         ]
       }}
    end)

    private_conn = init_test_session(conn, %{privacy: true})
    {:ok, activity_view, _} = live(private_conn, "/sessions/tg:1:0?tab=activity")
    render_click(activity_view, "transcripts_reveal", %{})

    assert has_element?(
             activity_view,
             "#session-agent-activity",
             "privacy-masked compaction result"
           )

    refute has_element?(
             activity_view,
             "#session-agent-activity",
             "exact sensitive compaction result"
           )

    refute render(activity_view) =~ "SECRET-PRIVATE-SUMMARY"

    {:ok, context_view, _} = live(private_conn, "/sessions/tg:1:0?tab=context")
    render_click(context_view, "transcripts_reveal", %{})
    assert has_element?(context_view, "#session-compaction-detail", "masked by privacy mode")
    refute has_element?(context_view, "#session-compaction-detail", "exact applied memory")
  end

  test "activity never calls a parser-unmatched summary applied memory", %{conn: conn} do
    applied = structured_event("applied", 8)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           applied,
           structured_summary(false, 9, applied, "Unmatched sensitive summary")
         ]
       }}
    end)

    {:ok, context_view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(context_view, "transcripts_reveal", %{})
    refute has_element?(context_view, "#session-compaction-detail", "exact applied memory")

    {:ok, activity_view, _} = live(conn, "/sessions/tg:1:0?tab=activity")
    refute render(activity_view) =~ "Unmatched sensitive summary"
    render_click(activity_view, "transcripts_reveal", %{})
    assert has_element?(activity_view, "#session-agent-activity", "summary · unmatched")

    assert has_element?(
             activity_view,
             "#session-agent-activity",
             "parser did not match this to applied evidence"
           )

    refute has_element?(activity_view, "#session-agent-activity", "applied memory")
  end

  test "a legacy COMPACT summary is never outcome evidence", %{
    conn: conn
  } do
    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           %{
             "timestamp" => "2026-07-13 07:17:31",
             "role" => "compact",
             "content" => "System/persona and retained decisions"
           }
         ]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})

    assert has_element?(view, "#session-compaction-status", "No event observed")
    assert has_element?(view, "#session-compaction-detail", "legacy")
    refute has_element?(view, "#session-compaction-detail .badge-warning")
    refute render(view) =~ "Legacy · ambiguous"
  end

  test "future events and malformed summaries never render as applied evidence", %{conn: conn} do
    future = structured_event("requested", 12)
    applied = structured_event("applied", 13)

    malformed_summary =
      structured_summary(true, 14, applied, "MALFORMED-FUTURE-SUMMARY")
      |> Map.delete("compaction_applied_sequence")

    unmatched_summary =
      structured_summary(false, 15, applied, "UNMATCHED-SENSITIVE-SUMMARY")

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [future, malformed_summary, unmatched_summary]
       }}
    end)

    {:ok, context_view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(context_view, "transcripts_reveal", %{})
    assert has_element?(context_view, "#session-compaction-status", "No event observed")
    refute has_element?(context_view, "#session-compaction-detail", "Applied")

    {:ok, activity_view, _} = live(conn, "/sessions/tg:1:0?tab=activity")
    render_click(activity_view, "transcripts_reveal", %{})
    assert has_element?(activity_view, "#session-agent-activity", "summary · unmatched")
    refute has_element?(activity_view, "#session-agent-activity", "applied memory")
  end

  test "revealed compaction outcome refreshes when the session snapshot moves", %{conn: conn} do
    state = start_supervised!({Agent, fn -> "applied" end})

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      event = Agent.get(state, & &1)
      {:ok, %{"source" => "slot", "logs" => [structured_event(event, 8)]}}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
    render_click(view, "transcripts_reveal", %{})
    assert has_element?(view, "#session-compaction-status", "Applied")

    Agent.update(state, fn _ -> "failed" end)

    moved =
      update_in(@snap["sessions"], fn [session] ->
        [Map.put(session, "last_activity", "2026-07-12T12:01:00Z")]
      end)

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, moved})

    # The snapshot handler enqueues a separate :load. Render once to cross that
    # message boundary before asserting against the refreshed evidence.
    _ = render(view)

    assert has_element?(view, "#session-compaction-status", "Failed")
    assert has_element?(view, "#session-compaction-detail", "http_failed")
  end

  test "all lean outcomes render distinct truthful badges and applied stays neutral", %{
    conn: conn
  } do
    cases = [
      {"applied", "Applied", ".badge-neutral"},
      {"skipped", "Skipped", ".badge-ghost"},
      {"rejected", "Rejected", ".badge-warning"},
      {"failed", "Failed", ".badge-error"}
    ]

    for {event, label, selector} <- cases do
      stub(SwarmClientMock, :session_logs, fn _, _ ->
        {:ok,
         %{
           "source" => "slot",
           "logs" => [structured_event(event, 9)]
         }}
      end)

      {:ok, view, _} = live(conn, "/sessions/tg:1:0?tab=context")
      render_click(view, "transcripts_reveal", %{})

      assert has_element?(view, "#session-compaction-detail #{selector}", label)
      assert has_element?(view, "#session-compaction-status", label)

      if event == "applied" do
        refute has_element?(view, "#session-compaction-detail .badge-success")
      end
    end
  end

  test "privacy mode masks summary bodies while preserving safe lean metadata", %{conn: conn} do
    applied = structured_event("applied", 10)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [
           applied,
           structured_summary(true, 11, applied, "SECRET-PRIVATE-CONTEXT")
         ]
       }}
    end)

    for tab <- ["context", "activity"] do
      private_conn = init_test_session(conn, %{privacy: true})
      {:ok, view, _} = live(private_conn, "/sessions/tg:1:0?tab=#{tab}")
      render_click(view, "transcripts_reveal", %{})
      html = render(view)

      refute html =~ "SECRET-PRIVATE-CONTEXT"
      assert html =~ "source record 10"
    end
  end

  defp structured_event(event, source_record_index) do
    payload =
      if event == "applied" do
        %{
          "event" => "applied",
          "before_messages" => 12,
          "after_messages" => 5,
          "before_bytes" => 12_000,
          "after_bytes" => 4_000
        }
      else
        %{"event" => event, "reason" => outcome_reason(event)}
      end

    %{
      "timestamp" => "2026-07-12 11:58:00",
      "role" => "compact",
      "entry_type" => "compaction_event",
      "integrity" => "structured_v2",
      "sensitive" => false,
      "source" => @parser_source,
      "content_complete" => true,
      "source_record_index" => source_record_index,
      "source_record_id" => %{
        "session_id" => "session.jsonl",
        "record_index" => source_record_index
      },
      "sequence" => source_record_index * 10,
      "content" => "UNSPECIFIED-CANARY-RAW",
      "compaction" => payload
    }
  end

  defp outcome_reason("skipped"), do: "router_declined"
  defp outcome_reason("rejected"), do: "invalid_response"
  defp outcome_reason("failed"), do: "http_failed"
  defp outcome_reason(_future_event), do: "router_declined"

  defp structured_summary(matched?, source_record_index, applied, content) do
    summary = %{
      "timestamp" => "2026-07-12 11:58:01",
      "role" => "compact_summary",
      "entry_type" => "compaction_summary",
      "integrity" => "structured_v2",
      "sensitive" => true,
      "source" => @parser_source,
      "content_complete" => true,
      "source_record_index" => source_record_index,
      "source_record_id" => %{
        "session_id" => "session.jsonl",
        "record_index" => source_record_index
      },
      "sequence" => if(matched?, do: applied["sequence"] + 1, else: source_record_index * 10),
      "compaction_summary_matched_applied" => matched?,
      "content" => content
    }

    if matched? do
      Map.merge(summary, %{
        "compaction_applied_source_record_index" => applied["source_record_index"],
        "compaction_applied_sequence" => applied["sequence"],
        "compaction_applied_source_record_id" => applied["source_record_id"]
      })
    else
      summary
    end
  end
end
