defmodule SubzeroSwarmDashboardWeb.ReplyHealthTest do
  # counts/3 feeds Overview's attention tile — it must agree with the Sessions
  # page because both call the same classifier. Covered here: the aggregation;
  # the classifier's decision order is pinned in sessions_live_reply_status_test.
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ReplyHealth

  @iso "2026-06-03T15:22:01Z"
  @in_s @iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()

  test "counts split unanswered from suppressed over the snapshot" do
    snap = %{
      "sessions" => [
        %{"session_id" => "tg:1:0", "last_activity" => @iso},
        %{"session_id" => "tg:2:0", "last_activity" => @iso},
        %{"session_id" => "tg:3:0", "last_activity" => nil}
      ],
      "extensions" => %{"deliveries" => %{"items" => []}}
    }

    story = %{story: [%{kind: "reply_suppressed", cid: "tg:2:0", ts: @in_s + 3.0}]}

    assert ReplyHealth.counts(snap, story, @in_s + 300) == %{unanswered: 1, suppressed: 1}
  end

  test "nil snapshot/story count zero (page boots before the first snapshot)" do
    assert ReplyHealth.counts(nil, nil, 0) == %{unanswered: 0, suppressed: 0}
  end
end
