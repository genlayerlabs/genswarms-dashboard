defmodule SubzeroSwarmDashboard.Story.State do
  @moduledoc """
  Folded lifecycle state of the display-event feed: open/closed request episodes,
  agent activity, the story + issues rings, and since-baseline KPI counters.
  Pure data — all mutation goes through `Story.Reducer`. Ring bounds and the
  stall threshold are captured at construction so the fold never reads config.

  `now` is the feed-anchored clock (max event ts + monotonic delta, set by
  `Reducer.tick/2`) — never the container's wall clock, so host↔container skew
  can't show up as wrong ages.
  """

  defstruct open: %{},
            # cid → display label (adapter-provided, e.g. a chat handle), refreshed
            # from each /dashboard snapshot
            # (events carry only the cid). `user/2` resolves through this, falling
            # back to the raw chat id so a not-yet-rostered live session still renders.
            users: %{},
            closed: [],
            agents: %{},
            story: [],
            issues: [],
            counters: %{
              replies: 0,
              reply_durations: [],
              first_feedback_durations: [],
              browse_ok: 0,
              browse_total: 0,
              browse_blocked: 0,
              asks: 0,
              compactions: 0,
              inbox_full: 0,
              failures: 0,
              stalled: 0,
              feed_gaps: 0
            },
            now: nil,
            story_max: 500,
            issues_max: 200,
            closed_max: 200,
            samples_max: 500,
            stall_after_ms: 180_000,
            # turn-end is invisible to the feed (no engine turn-complete event), so
            # claimed activity DECAYS when an agent stops producing events: thinking
            # quickly (a finished turn), waiting slowly (a lost browse_done)
            think_decay_ms: 60_000,
            wait_decay_ms: 300_000,
            # issues age out of the ring after this window (tick-time filter)
            issue_window_s: 86_400

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc """
  The SMALL per-tick summary broadcast to every LiveView: in-flight rows, agent
  strip, KPI counters, issues tail, last ~50 story rows. The full rings stay in
  the state, pulled on demand (`EventsFeed.story_ring/0`, `EventsFeed.episodes/1`).
  """
  def summary(%__MODULE__{} = state) do
    now = state.now || 0.0

    %{
      in_flight: in_flight(state, now),
      agents: agent_strip(state, now),
      kpis: kpis(state),
      issues: Enum.take(state.issues, 20),
      story: Enum.take(state.story, 50)
    }
  end

  @doc "Episodes for one cid, newest first (the open one, then closed legs)."
  def episodes(%__MODULE__{} = state, cid) do
    open =
      case state.open[cid] do
        nil -> []
        ep -> [ep]
      end

    open ++ Enum.filter(state.closed, &(&1.cid == cid))
  end

  @doc "Nearest-rank percentile (q in 0..1); nil on an empty sample set."
  def percentile([], _q), do: nil
  def percentile(samples, q) when is_list(samples), do: sorted_percentile(Enum.sort(samples), q)

  # kpis/1 runs on every 700ms broadcast — sort each sample list once, not once
  # per quantile pulled from it
  defp sorted_percentile([], _q), do: nil

  defp sorted_percentile(sorted, q),
    do: Enum.at(sorted, max(ceil(q * length(sorted)) - 1, 0))

  defp in_flight(state, now) do
    state.open
    |> Map.values()
    |> Enum.sort_by(& &1.opened_at)
    |> Enum.map(fn ep ->
      %{
        cid: ep.cid,
        user: ep.user,
        agent: ep.agent,
        count: ep.count,
        opened_at: ep.opened_at,
        elapsed_s: elapsed(now, ep.opened_at),
        stalled: ep.stalled,
        activity: activity(state, ep.agent)
      }
    end)
  end

  defp agent_strip(state, now) do
    state.agents
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn ag ->
      %{
        name: ag.name,
        state: ag.state,
        wait_on: ag.wait_on,
        queue: ag.queue,
        since: ag.since,
        elapsed_s: elapsed(now, ag.since)
      }
    end)
  end

  defp kpis(state) do
    c = state.counters
    reply_sorted = Enum.sort(c.reply_durations)

    %{
      replies: c.replies,
      reply_p50: sorted_percentile(reply_sorted, 0.5),
      reply_p95: sorted_percentile(reply_sorted, 0.95),
      first_feedback_p50: percentile(c.first_feedback_durations, 0.5),
      browse_ok: c.browse_ok,
      browse_total: c.browse_total,
      browse_blocked: c.browse_blocked,
      asks: c.asks,
      compactions: c.compactions,
      inbox_full: c.inbox_full,
      failures: c.failures,
      stalled: Enum.count(state.open, fn {_cid, ep} -> ep.stalled end),
      feed_gaps: c.feed_gaps
    }
  end

  defp activity(_state, nil), do: "routing"

  defp activity(state, name) do
    case state.agents[name] do
      %{state: :waiting, wait_on: wait_on} -> "waiting on #{wait_on || "?"}"
      %{state: :thinking} -> "thinking"
      %{state: :spawning} -> "spawning"
      _ -> "idle"
    end
  end

  defp elapsed(now, since), do: max(now - (since || now), 0.0)
end
