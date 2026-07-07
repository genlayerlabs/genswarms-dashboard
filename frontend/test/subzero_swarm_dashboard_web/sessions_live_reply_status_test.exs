defmodule SubzeroSwarmDashboardWeb.SessionsLiveReplyStatusTest do
  # Unit tests for reply_status/3 — the reply-health classifier. The contract it
  # guards is that EVERY timestamp is unix SECONDS: `now` and a delivery's `at`
  # are System.os_time(:second)-scale (the sender stamps `at: os_time(:second)`),
  # and `last_activity` is an ISO8601 string. A unit slip (treating `at` as ms)
  # would silently break the badge — these tests pin all four states + boundaries.
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboardWeb.SessionsLive

  @iso "2026-06-03T15:22:01Z"
  @in_s @iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()

  # grace = 120s, skew = 5s (mirror of the LiveView module attrs)

  defp session(last \\ @iso, sid \\ "tg:1:0"),
    do: %{"session_id" => sid, "last_activity" => last}

  defp deliv(at, sid \\ "tg:1:0", status \\ "sent"),
    do: %{sid => %{"at" => at, "status" => status}}

  test "idle when there is no last inbound" do
    assert SessionsLive.reply_status(session(nil), %{}, @in_s + 5) == :idle
    assert SessionsLive.reply_status(session(""), %{}, @in_s + 5) == :idle
  end

  test "answered when a delivery lands at/after the inbound" do
    assert SessionsLive.reply_status(session(), deliv(@in_s + 10), @in_s + 10) == :answered
    # boundary: a delivery exactly skew-seconds BEFORE the inbound still counts
    # (clock skew between ingress and sender), one second further does not.
    assert SessionsLive.reply_status(session(), deliv(@in_s - 5), @in_s) == :answered
    assert SessionsLive.reply_status(session(), deliv(@in_s - 6), @in_s + 1) == :pending
  end

  test "pending inside the grace window, unanswered past it (no delivery)" do
    assert SessionsLive.reply_status(session(), %{}, @in_s + 120) == :pending
    assert SessionsLive.reply_status(session(), %{}, @in_s + 121) == :unanswered
  end

  test "a delivery for ANOTHER conversation does not count as answered" do
    assert SessionsLive.reply_status(session(), deliv(@in_s + 10, "tg:other:0"), @in_s + 30) ==
             :pending
  end

  test "unit contract: `at` is seconds (a seconds-scale just-after delivery is answered)" do
    # @in_s is ~1.7e9 (seconds). If reply_status compared it against a ms-scale
    # last_in (×1000 ≈ 1.7e12), a real seconds `at` would read as far in the past
    # and never be :answered. It is, because both sides are seconds.
    assert SessionsLive.reply_status(session(), deliv(@in_s + 1), @in_s + 1) == :answered
  end

  # ── :suppressed (4-arity — suppressed ts per cid from the story tail) ────────
  # "The bot CHOSE silence" (spam window) must stop rendering as the same badge
  # as a real stall: during the 2026-07-07 prod incident 6 of 15 "no reply" rows
  # were suppressions, and the operator could not tell policy from outage.

  test "suppressed when a reply_suppressed row lands at/after the inbound" do
    supp = %{"tg:1:0" => @in_s + 3.0}
    assert SessionsLive.reply_status(session(), %{}, supp, @in_s + 300) == :suppressed
  end

  test "a real delivery wins over a suppression (answered ranks first)" do
    supp = %{"tg:1:0" => @in_s + 3.0}
    assert SessionsLive.reply_status(session(), deliv(@in_s + 10), supp, @in_s + 300) == :answered
  end

  test "a suppression OLDER than the inbound does not mask a true no-reply" do
    supp = %{"tg:1:0" => @in_s - 60.0}
    assert SessionsLive.reply_status(session(), %{}, supp, @in_s + 300) == :unanswered
  end

  test "a suppression for ANOTHER conversation does not count" do
    supp = %{"tg:other:0" => @in_s + 3.0}
    assert SessionsLive.reply_status(session(), %{}, supp, @in_s + 300) == :unanswered
  end

  test "3-arity keeps its contract (no suppression info → never :suppressed)" do
    assert SessionsLive.reply_status(session(), %{}, @in_s + 300) == :unanswered
  end

  # ── attention-first sort ─────────────────────────────────────────────────────

  test "sort_by_attention: unanswered (oldest first) → pending → suppressed → answered → idle (newest first)" do
    mk = fn sid, iso -> %{"session_id" => sid, "last_activity" => iso} end
    statuses = %{
      "a-old" => :unanswered,
      "a-new" => :unanswered,
      "p" => :pending,
      "s" => :suppressed,
      "ok" => :answered,
      "i-old" => :idle,
      "i-new" => :idle
    }

    sessions = [
      mk.("i-old", "2026-06-01T00:00:00Z"),
      mk.("ok", "2026-06-03T12:00:00Z"),
      mk.("a-new", "2026-06-03T15:00:00Z"),
      mk.("s", "2026-06-03T14:00:00Z"),
      mk.("i-new", "2026-06-03T10:00:00Z"),
      mk.("a-old", "2026-06-03T09:00:00Z"),
      mk.("p", "2026-06-03T15:30:00Z")
    ]

    assert Enum.map(SessionsLive.sort_by_attention(sessions, statuses), & &1["session_id"]) ==
             ["a-old", "a-new", "p", "s", "ok", "i-new", "i-old"]
  end
end
