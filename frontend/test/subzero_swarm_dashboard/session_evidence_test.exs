defmodule SubzeroSwarmDashboard.SessionEvidenceTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.SessionEvidence

  test "projects live slot evidence without copying raw bodies" do
    evidence =
      SessionEvidence.build(
        transcript:
          {:ok,
           %{
             "source" => "store",
             "turns" => [%{"role" => "user", "content" => "SECRET-TURN"}]
           }},
        skills:
          {:ok,
           %{
             "source" => "slot",
             "skills" => [%{"name" => "soul.md", "content" => "SECRET-SKILL"}]
           }},
        activity:
          {:ok,
           %{
             "source" => "slot",
             "logs" => [%{"role" => "user", "content" => "SECRET-LOG"}]
           }}
      )

    assert evidence.availability == :live_slot
    assert evidence.turns == %{state: :available, count: 1, source: "store"}
    assert evidence.skills == %{state: :slot, count: 1, bytes: 12, source: "slot"}
    assert evidence.activity == %{state: :slot, count: 1, source: "slot"}
    assert evidence.compaction == %{state: :not_observed, at: nil, summary_available: false}

    inspected = inspect(evidence)
    refute inspected =~ "SECRET-TURN"
    refute inspected =~ "SECRET-SKILL"
    refute inspected =~ "SECRET-LOG"
  end

  test "counts skill bytes rather than graphemes" do
    evidence =
      SessionEvidence.build(
        transcript: :hidden,
        activity: :hidden,
        skills:
          {:ok,
           %{
             "source" => "pool",
             "skills" => [
               %{"content" => "á"},
               %{"content" => "🪽"},
               %{"name" => "missing-content.md"}
             ]
           }}
      )

    assert evidence.availability == :sensitive_hidden
    assert evidence.skills == %{state: :pool, count: 3, bytes: 6, source: "pool"}
  end

  test "projects only the four exact lean outcomes" do
    applied = evidence_for([compaction_event("applied", 7)])

    assert applied.compaction == %{
             state: :applied,
             event: "applied",
             source_record_index: 7,
             at: "display-only-late",
             integrity: :structured_v2,
             before_messages: 12,
             after_messages: 5,
             before_bytes: 12_000,
             after_bytes: 4_000,
             summary_available: false
           }

    for event <- ~w(skipped rejected failed) do
      reason = outcome_reason(event)
      evidence = evidence_for([compaction_event(event, 8)])

      assert evidence.compaction == %{
               state: String.to_existing_atom(event),
               event: event,
               reason: reason,
               source_record_index: 8,
               at: "display-only-late",
               integrity: :structured_v2,
               summary_available: false
             }
    end
  end

  test "accepts an applied compaction that reduces bytes without reducing message count" do
    event =
      compaction_event("applied", 7)
      |> put_in(["compaction", "before_messages"], 15)
      |> put_in(["compaction", "after_messages"], 15)
      |> put_in(["compaction", "before_bytes"], 14_647)
      |> put_in(["compaction", "after_bytes"], 12_915)

    assert %{
             state: :applied,
             before_messages: 15,
             after_messages: 15,
             before_bytes: 14_647,
             after_bytes: 12_915
           } = SessionEvidence.classify_compaction_entry(event)

    assert evidence_for([event]).compaction.state == :applied
  end

  test "selects the last valid parser event without timestamp correlation" do
    earlier_timestamp =
      compaction_event("applied", 1)
      |> Map.put("timestamp", "2099-12-31 23:59:59")

    later_source_record =
      compaction_event("failed", 2)
      |> Map.put("timestamp", "2000-01-01 00:00:00")

    evidence = evidence_for([earlier_timestamp, later_source_record])

    assert evidence.compaction.state == :failed
    assert evidence.compaction.source_record_index == 2
    assert evidence.compaction.at == "2000-01-01 00:00:00"
  end

  test "rejects old, malformed, extra-field, and future event shapes as evidence" do
    base = compaction_event("applied", 1)

    malformed = [
      put_in(base, ["compaction", "event"], "requested"),
      put_in(base, ["compaction", "event"], "timed_out"),
      put_in(base, ["compaction", "event"], "cancelled"),
      base
      |> Map.put("compaction", %{"event" => "failed", "reason" => "future_reason"}),
      base
      |> Map.put("compaction", %{"event" => "failed", "reason" => "router_declined"}),
      put_in(base, ["compaction", "operation_id"], "old-id"),
      put_in(base, ["compaction", "snapshot_hash"], "old-hash"),
      put_in(base, ["compaction", "manifest"], %{}),
      put_in(base, ["compaction", "schema"], 3),
      put_in(base, ["compaction", "after_messages"], 13),
      put_in(base, ["compaction", "after_bytes"], 12_000),
      put_in(base, ["compaction", "before_messages"], 1.5),
      Map.put(base, "content_complete", false),
      Map.put(base, "integrity", "future"),
      Map.delete(base, "source"),
      put_in(base, ["source", "parser"], "genswarms.subzeroclaw_log.v2"),
      put_in(base, ["source", "format"], "subzeroclaw.text.v1"),
      put_in(base, ["source", "scope"], "future_scope"),
      put_in(base, ["source", "integrity"], "future"),
      Map.put(base, "role", "compact_summary"),
      Map.put(base, "sensitive", true),
      Map.delete(base, "source_record_id")
    ]

    for entry <- malformed do
      refute SessionEvidence.compaction_entry?(entry)
      assert evidence_for([entry]).compaction.state == :not_observed
    end
  end

  test "uses parser-provided matched summary metadata for applied availability" do
    event = compaction_event("applied", 3)
    matched = compaction_summary(true, 4, event)
    unmatched = compaction_summary(false, 4, event)

    assert evidence_for([event, matched]).compaction.summary_available
    refute evidence_for([event, unmatched]).compaction.summary_available

    assert %{matched_applied: true} = SessionEvidence.classify_compaction_entry(matched)
    assert %{matched_applied: false} = SessionEvidence.classify_compaction_entry(unmatched)
    refute inspect(evidence_for([event, matched])) =~ "SECRET-SUMMARY"
  end

  test "accepts every exact event and reason emitted by SubZeroClaw v3" do
    reasons = %{
      "skipped" => ~w(not_enough_groups router_declined insufficient_reduction),
      "rejected" => ~w(invalid_layout invalid_response invalid_contract unsafe_summary),
      "failed" => ~w(allocation_failed http_failed)
    }

    for {event, event_reasons} <- reasons, reason <- event_reasons do
      entry =
        compaction_event(event, 9)
        |> put_in(["compaction", "reason"], reason)

      assert %{event: ^event, reason: ^reason} =
               SessionEvidence.classify_compaction_entry(entry)
    end
  end

  test "matched summary must identify the selected applied source record exactly" do
    selected = compaction_event("applied", 3)
    other = compaction_event("applied", 6)
    summary_for_other = compaction_summary(true, 7, other)

    refute evidence_for([other, summary_for_other, selected]).compaction.summary_available

    inconsistent =
      summary_for_other
      |> Map.put("compaction_applied_source_record_index", 5)

    refute SessionEvidence.compaction_entry?(inconsistent)
    refute evidence_for([other, inconsistent]).compaction.summary_available
  end

  test "rejects malformed summary match claims and future summary fields" do
    event = compaction_event("applied", 2)
    matched = compaction_summary(true, 3, event)
    unmatched = compaction_summary(false, 3, event)

    malformed = [
      Map.delete(matched, "compaction_applied_source_record_index"),
      Map.delete(matched, "compaction_applied_sequence"),
      Map.delete(matched, "compaction_applied_source_record_id"),
      Map.put(matched, "compaction_applied_sequence", "2"),
      put_in(matched, ["compaction_applied_source_record_id", "record_index"], 99),
      Map.put(matched, "sequence", matched["sequence"] + 1),
      put_in(matched, ["source_record_id", "session_id"], "other.jsonl"),
      Map.put(matched, "content", "   "),
      Map.put(matched, "content_complete", false),
      Map.delete(matched, "source"),
      put_in(matched, ["source", "parser"], "genswarms.subzeroclaw_log.v4"),
      Map.put(matched, "role", "compact"),
      Map.put(matched, "sensitive", false),
      Map.put(unmatched, "compaction_applied_source_record_index", 2)
    ]

    for summary <- malformed do
      refute SessionEvidence.compaction_entry?(summary)
    end
  end

  test "legacy and invalid parser records never become compaction evidence" do
    entries = [
      %{"timestamp" => "t", "role" => "compact", "content" => "legacy summary"},
      %{"timestamp" => "t", "role" => "sys", "content" => "context compacted"},
      %{
        "entry_type" => "invalid_compaction",
        "role" => "compact",
        "content" => ~s({"event":"applied"})
      },
      %{
        "entry_type" => "invalid_compaction_summary",
        "role" => "compact_summary",
        "content" => "future summary"
      }
    ]

    refute Enum.any?(entries, &SessionEvidence.compaction_entry?/1)
    assert evidence_for(entries).compaction.state == :not_observed
  end

  test "loading hidden unavailable and empty responses remain distinct and total" do
    loading = SessionEvidence.build(transcript: :loading, skills: :loading, activity: :loading)
    hidden = SessionEvidence.build(transcript: :hidden, skills: :loading, activity: :hidden)
    malformed = SessionEvidence.build(transcript: {:ok, %{}}, skills: {:ok, nil}, activity: :oops)

    empty =
      SessionEvidence.build(
        transcript: {:ok, %{"source" => "store", "turns" => []}},
        skills: {:ok, %{"source" => "unavailable", "skills" => []}},
        activity: {:ok, %{"source" => "unavailable", "logs" => []}}
      )

    assert loading.availability == :unavailable
    assert loading.turns.state == :loading
    assert loading.skills.state == :loading
    assert loading.activity.state == :loading
    assert loading.compaction.state == :unknown

    assert hidden.availability == :sensitive_hidden
    assert hidden.turns.state == :hidden
    assert hidden.activity.state == :hidden
    assert hidden.compaction.state == :hidden

    assert malformed.availability == :unavailable
    assert malformed.compaction.state == :unknown

    assert empty.availability == :components_only
    assert empty.turns == %{state: :empty, count: 0, source: "store"}
    assert empty.skills == %{state: :unavailable, count: 0, bytes: 0, source: "unavailable"}
    assert empty.activity.state == :unavailable
  end

  test "transcript and skills source matrices preserve availability semantics" do
    transcript_cases = [
      {{:ok, %{"source" => "store", "turns" => []}}, :empty, :components_only},
      {{:ok, %{"source" => "store", "turns" => [%{"content" => "x"}]}}, :available,
       :components_only},
      {{:ok, %{"source" => "unavailable", "turns" => []}}, :unavailable, :unavailable},
      {:loading, :loading, :unavailable},
      {{:ok, %{"source" => "store", "turns" => :bad}}, :unavailable, :unavailable}
    ]

    for {input, state, availability} <- transcript_cases do
      evidence = SessionEvidence.build(transcript: input, skills: :loading, activity: :loading)
      assert evidence.turns.state == state
      assert evidence.availability == availability
    end

    skills_cases = [
      {{:ok, %{"source" => "slot", "skills" => []}}, :slot},
      {{:ok, %{"source" => "pool", "skills" => []}}, :pool},
      {{:ok, %{"source" => "future", "skills" => []}}, :empty},
      {{:ok, %{"source" => "unavailable", "skills" => []}}, :unavailable},
      {:loading, :loading}
    ]

    for {input, state} <- skills_cases do
      evidence = SessionEvidence.build(transcript: :hidden, skills: input, activity: :loading)
      assert evidence.skills.state == state
    end
  end

  test "slot activity is live evidence but non-slot activity never claims compaction" do
    slot =
      SessionEvidence.build(
        transcript: :hidden,
        skills: :loading,
        activity: {:ok, %{"source" => "slot", "logs" => []}}
      )

    non_slot =
      SessionEvidence.build(
        transcript: :hidden,
        skills: {:ok, %{"source" => "pool", "skills" => [%{"content" => "x"}]}},
        activity: {:ok, %{"source" => "agent_server", "logs" => [compaction_event("applied", 1)]}}
      )

    assert slot.availability == :live_slot
    assert slot.compaction.state == :not_observed
    assert non_slot.availability == :components_only
    assert non_slot.activity.state == :unavailable
    assert non_slot.compaction.state == :unknown
  end

  defp evidence_for(logs) do
    SessionEvidence.build(
      transcript: :hidden,
      skills: :loading,
      activity: {:ok, %{"source" => "slot", "logs" => logs}}
    )
  end

  defp compaction_event(event, source_record_index) do
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
      "timestamp" => "display-only-late",
      "entry_type" => "compaction_event",
      "integrity" => "structured_v2",
      "role" => "compact",
      "sensitive" => false,
      "source" => parser_source(),
      "content_complete" => true,
      "source_record_index" => source_record_index,
      "source_record_id" => %{
        "session_id" => "session.jsonl",
        "record_index" => source_record_index
      },
      "sequence" => source_record_index * 10,
      "compaction" => payload,
      "content" => "CANARY-RAW"
    }
  end

  defp outcome_reason("skipped"), do: "router_declined"
  defp outcome_reason("rejected"), do: "invalid_response"
  defp outcome_reason("failed"), do: "http_failed"

  defp compaction_summary(matched?, source_record_index, applied_event) do
    summary = %{
      "timestamp" => "display-only-summary",
      "entry_type" => "compaction_summary",
      "integrity" => "structured_v2",
      "role" => "compact_summary",
      "sensitive" => true,
      "source" => parser_source(),
      "content_complete" => true,
      "source_record_index" => source_record_index,
      "source_record_id" => %{
        "session_id" => "session.jsonl",
        "record_index" => source_record_index
      },
      "sequence" =>
        if(matched?, do: applied_event["sequence"] + 1, else: source_record_index * 10),
      "content" => "SECRET-SUMMARY",
      "compaction_summary_matched_applied" => matched?
    }

    if matched? do
      Map.merge(summary, %{
        "compaction_applied_source_record_index" => applied_event["source_record_index"],
        "compaction_applied_sequence" => applied_event["sequence"],
        "compaction_applied_source_record_id" => applied_event["source_record_id"]
      })
    else
      summary
    end
  end

  defp parser_source do
    %{
      "format" => "subzeroclaw.jsonl.v2",
      "parser" => "genswarms.subzeroclaw_log.v3",
      "scope" => "log_file_snapshot",
      "integrity" => "structured_v2"
    }
  end
end
