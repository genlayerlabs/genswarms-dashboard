defmodule SubzeroSwarmDashboardWeb.ReplyHealth do
  @moduledoc """
  The reply-health classifier, shared by Sessions (per-row badges + sort) and
  Overview (the attention tile). One home for the thresholds and the decision
  order so the pages can never disagree about what "unanswered" means.

  ALL times are unix SECONDS: `now` and a delivery's `at` are
  `System.os_time(:second)`-scale, `last_activity` is an ISO8601 string, and a
  suppression ts is the feed event's float epoch seconds.
  """

  # A conversation whose last inbound has gone this long with no outbound
  # delivery is flagged; the skew absorbs clock drift between ingress
  # (inbound) and the sender (outbound).
  @reply_grace_s 120
  @reply_skew_s 5

  @doc """
  `:idle | :answered | :suppressed | :pending | :unanswered` for one session.

  A suppression at/after the inbound classifies `:suppressed` — the bot CHOSE
  silence (spam window), which must not render as the `:unanswered` alarm (a
  stall). A real delivery still wins: answered is checked first.
  """
  def status(session, deliveries, suppressed, now) do
    last_in = to_unix(session["last_activity"])
    last_send = (deliveries[session["session_id"]] || %{})["at"]
    last_supp = suppressed[session["session_id"]]

    cond do
      is_nil(last_in) -> :idle
      is_integer(last_send) and last_send >= last_in - @reply_skew_s -> :answered
      is_number(last_supp) and last_supp >= last_in - @reply_skew_s -> :suppressed
      now - last_in <= @reply_grace_s -> :pending
      true -> :unanswered
    end
  end

  @doc "cid => latest delivery, from the sender's dashboard extension."
  def deliveries(nil), do: %{}

  def deliveries(snap) do
    (get_in(snap, ["extensions", "deliveries", "items"]) || [])
    |> Map.new(fn d -> {d["session_id"], d} end)
  end

  @doc """
  cid => latest reply_suppressed ts, from the story tail (the reducer already
  folds the feed's reply_suppressed events — nothing new crosses the wire).
  """
  def suppressed_by_cid(nil), do: %{}

  def suppressed_by_cid(story) do
    (story[:story] || [])
    |> Enum.filter(&(&1.kind == "reply_suppressed" and is_binary(&1.cid)))
    |> Enum.reduce(%{}, fn r, acc -> Map.update(acc, r.cid, r.ts, &max(&1, r.ts)) end)
  end

  @doc "cid => status for every session in the snapshot, one pass."
  def statuses(snap, story, now) do
    deliveries = deliveries(snap)
    suppressed = suppressed_by_cid(story)

    Map.new(
      (snap && snap["sessions"]) || [],
      &{&1["session_id"], status(&1, deliveries, suppressed, now)}
    )
  end

  @doc "%{unanswered: n, suppressed: m} over the whole snapshot — the Overview tile."
  def counts(snap, story, now) do
    statuses = statuses(snap, story, now)

    %{
      unanswered: Enum.count(statuses, fn {_, st} -> st == :unanswered end),
      suppressed: Enum.count(statuses, fn {_, st} -> st == :suppressed end)
    }
  end

  defp to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp to_unix(_), do: nil
end
