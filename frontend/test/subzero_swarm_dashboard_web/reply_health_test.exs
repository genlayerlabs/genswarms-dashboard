defmodule SubzeroSwarmDashboardWeb.ReplyHealthTest do
  # counts/3 feeds Overview's attention tile — it must agree with the Sessions
  # page because both call the same classifier. Covered here: the aggregation;
  # the classifier's decision order is pinned in sessions_live_reply_status_test.
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ReplyHealth

  @iso "2026-06-03T15:22:01Z"
  @in_s @iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()

  test "sessions explicitly outside reply tracking remain unavailable" do
    session = %{
      "session_id" => "group",
      "last_activity" => @iso,
      "reply_tracking_available" => false
    }

    assert ReplyHealth.status(session, %{}, %{}, @in_s + 300) == :unavailable

    assert ReplyHealth.status(
             Map.delete(session, "reply_tracking_available"),
             %{},
             %{},
             @in_s + 300
           ) == :unanswered
  end

  test "failed delivery never answers an inbound message" do
    session = %{"session_id" => "tg:1:0", "last_activity" => @iso}

    for status <- ["unreachable", "failed", nil] do
      replies = %{"tg:1:0" => %{"status" => status, "at" => @in_s + 10}}
      assert ReplyHealth.status(session, replies, %{}, @in_s + 300) == :unanswered
    end
  end

  test "generic proactive deliveries are not evidence of a reply" do
    snap = %{
      "sessions" => [%{"session_id" => "tg:1:0", "last_activity" => @iso}],
      "extensions" => %{
        "deliveries" => %{
          "items" => [%{"session_id" => "tg:1:0", "status" => "sent", "at" => @in_s + 10}]
        },
        "replies" => %{"available" => true, "items" => []}
      }
    }

    assert ReplyHealth.statuses(snap, nil, @in_s + 300) == %{"tg:1:0" => :unanswered}
    reply = %{"session_id" => "tg:1:0", "status" => "sent", "at" => @in_s + 5}
    snap = put_in(snap, ["extensions", "replies", "items"], [reply])
    assert ReplyHealth.statuses(snap, nil, @in_s + 300) == %{"tg:1:0" => :answered}
  end

  test "missing or failed reply evidence stays unavailable, with suppression and grace preserved" do
    base = %{
      "sessions" => [%{"session_id" => "tg:1:0", "last_activity" => @iso}],
      "extensions" => %{}
    }

    for snap <- [
          base,
          put_in(base, ["extensions", "replies"], %{"available" => false, "items" => []})
        ] do
      assert ReplyHealth.statuses(snap, nil, @in_s + 300) == %{"tg:1:0" => :unavailable}
      assert ReplyHealth.statuses(snap, nil, @in_s + 30) == %{"tg:1:0" => :pending}
      story = %{story: [%{kind: "reply_suppressed", cid: "tg:1:0", ts: @in_s + 3}]}
      assert ReplyHealth.statuses(snap, story, @in_s + 300) == %{"tg:1:0" => :suppressed}
    end
  end

  test "counts split unanswered from suppressed over the snapshot" do
    snap = %{
      "sessions" => [
        %{"session_id" => "tg:1:0", "last_activity" => @iso},
        %{"session_id" => "tg:2:0", "last_activity" => @iso},
        %{"session_id" => "tg:3:0", "last_activity" => nil}
      ],
      "extensions" => %{"replies" => %{"available" => true, "items" => []}}
    }

    story = %{story: [%{kind: "reply_suppressed", cid: "tg:2:0", ts: @in_s + 3.0}]}

    assert ReplyHealth.counts(snap, story, @in_s + 300) ==
             %{unanswered: 1, suppressed: 1, stale: 0, unavailable: 0}
  end

  test "counts age unanswered rows into stale — Overview's alarm only counts fresh waits" do
    snap = %{
      "sessions" => [
        %{"session_id" => "tg:fresh:0", "last_activity" => @iso},
        %{"session_id" => "tg:old:0", "last_activity" => "2026-05-01T00:00:00Z"}
      ],
      "extensions" => %{"replies" => %{"available" => true, "items" => []}}
    }

    assert ReplyHealth.counts(snap, %{story: []}, @in_s + 300) ==
             %{unanswered: 1, suppressed: 0, stale: 1, unavailable: 0}
  end

  test "nil snapshot/story count zero (page boots before the first snapshot)" do
    assert ReplyHealth.counts(nil, nil, 0) == %{
             unanswered: 0,
             suppressed: 0,
             stale: 0,
             unavailable: 0
           }
  end
end
