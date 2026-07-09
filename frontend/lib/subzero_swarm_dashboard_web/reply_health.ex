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

  # Past this, an unanswered conversation ages into :stale — still visible,
  # no longer alarmed. "⚠ no reply" must mean someone is waiting NOW; without
  # decay the alarm count converges on the roster size and reads as wallpaper.
  @stale_after_s 48 * 3600

  @doc """
  `:idle | :answered | :suppressed | :pending | :unanswered | :stale` for one
  session.

  A suppression at/after the inbound classifies `:suppressed` — the bot CHOSE
  silence (spam window), which must not render as the `:unanswered` alarm (a
  stall). A real delivery still wins: answered is checked first. Unanswered
  older than 48h decays to `:stale`.
  """
  def status(session, deliveries, suppressed, now) do
    last_in = to_unix(session["last_activity"])
    last_send = delivery_at((deliveries[session["session_id"]] || %{})["at"])
    last_supp = suppressed[session["session_id"]]

    cond do
      is_nil(last_in) -> :idle
      is_number(last_send) and last_send >= last_in - @reply_skew_s -> :answered
      is_number(last_supp) and last_supp >= last_in - @reply_skew_s -> :suppressed
      now - last_in <= @reply_grace_s -> :pending
      now - last_in > @stale_after_s -> :stale
      true -> :unanswered
    end
  end

  # The delivery `at` contract is unix SECONDS — but the old is_integer guard
  # made a host's contract slip (shipping its store's TEXT stamp) fail SILENTLY:
  # :answered never fired and the entire roster classified :unanswered with no
  # error anywhere (prod 2026-07-09, 754/758 false alarms). Be liberal in what
  # we accept: convert ISO8601 / naive-UTC strings; junk means "no evidence".
  defp delivery_at(v) when is_number(v), do: v

  defp delivery_at(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(v) do
          {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
          {:error, _} -> nil
        end
    end
  end

  defp delivery_at(_), do: nil

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

  @doc """
  %{unanswered: n, suppressed: m, stale: k} over the whole snapshot — the
  Overview tile reads unanswered/suppressed (fresh alarms only; stale is
  reported separately so aged rows can never re-inflate the alarm).
  """
  def counts(snap, story, now) do
    statuses = statuses(snap, story, now)

    %{
      unanswered: Enum.count(statuses, fn {_, st} -> st == :unanswered end),
      suppressed: Enum.count(statuses, fn {_, st} -> st == :suppressed end),
      stale: Enum.count(statuses, fn {_, st} -> st == :stale end)
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
