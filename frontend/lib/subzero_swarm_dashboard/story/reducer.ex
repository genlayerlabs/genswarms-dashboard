defmodule SubzeroSwarmDashboard.Story.Reducer do
  @moduledoc """
  PURE fold of display events into `Story.State` — the Elixir port of the
  prototype reducer that won the log-vs-events parity test
  (wingstonrallybot `prototype/dashboard/broker_events.py`).

  `apply/2` is total: kinds are additive (spec §2 compatibility rule), so an
  unknown kind — or a known one with missing fields — becomes a generic story
  row and never crashes or stalls the fold. Durations between event PAIRS use
  event `ts` on both ends; only `tick/2` takes a now (the feed-anchored clock).
  """

  alias SubzeroSwarmDashboard.Story.State

  @issue_window_s 86_400

  @doc "Fold one event (string-keyed, exactly as decoded from JSON). Total."
  def apply(%State{} = state, %{"kind" => kind} = ev), do: fold(kind, state, ev)
  def apply(%State{} = state, ev) when is_map(ev), do: fold(nil, state, ev)

  @doc """
  Wall-clock pass, run on every poll tick: refreshes the in-flight clock,
  classifies stalled episodes (exactly once each), expires the 24h issue window.
  """
  def tick(%State{} = state, now) do
    %{state | now: now}
    |> expire_issues(now)
    |> classify_stalled(now)
  end

  # ── kind → fold (lifecycle vocabulary identical to the prototype) ────────────

  defp fold("request_open", state, %{"cid" => cid} = ev) when is_binary(cid) do
    now = ts(ev, state)

    state =
      case state.open[cid] do
        # an open request gets a queued follow-up: merge, don't double-count
        %{} = ep -> put_open(state, %{ep | count: ep.count + 1, last_open: now})
        nil -> put_open(state, new_episode(cid, now))
      end

    row(state, ev, %{cid: cid, text: "▶ @#{user(cid)} request open"})
  end

  defp fold("routed", state, %{"cid" => cid, "slot" => slot} = ev)
       when is_binary(cid) and is_binary(slot) do
    now = ts(ev, state)
    ag = get_agent(state, slot)
    busy? = ag.state != :idle
    ep = state.open[cid]

    state =
      if ep && ep.agent == nil,
        do: put_open(state, %{ep | agent: slot}),
        else: state

    state =
      if busy?,
        do: put_agent(state, %{ag | queue: min(ag.queue + 1, 99)}),
        else: put_agent(state, %{ag | state: :thinking, wait_on: nil, since: now})

    if ep do
      note = if busy?, do: "queued behind current turn", else: "claims #{cid}"
      row(state, ev, %{cid: cid, agent: slot, text: "⟳ #{slot} #{note}"})
    else
      state
    end
  end

  defp fold("spawn_start", state, %{"slot" => slot} = ev) when is_binary(slot) do
    now = ts(ev, state)

    state =
      put_agent(state, %{get_agent(state, slot) | state: :spawning, wait_on: nil, since: now})

    row(state, ev, %{agent: slot, text: "⚙ #{slot} spawning"})
  end

  defp fold("teardown", state, %{"slot" => slot} = ev) when is_binary(slot) do
    state = put_agent(state, %{get_agent(state, slot) | state: :idle, wait_on: nil, queue: 0})
    row(state, ev, %{agent: slot, text: "✖ #{slot} torn down"})
  end

  defp fold("inbox_full", state, ev) do
    state = bump(state, :inbox_full)
    issue_row(state, ev, %{text: "⚠ rejected — inbox full"})
  end

  defp fold("ask", state, %{"from" => from} = ev) when is_binary(from) do
    now = ts(ev, state)
    ag = get_agent(state, from)
    # thinking refresh: keep the original since if already thinking
    since = if ag.state == :thinking, do: ag.since, else: now
    state = put_agent(state, %{ag | state: :thinking, wait_on: nil, since: since})
    state = bump(state, :asks)
    row(state, ev, %{agent: from, text: "⇄ #{from} asked policy"})
  end

  defp fold("browse_dispatch", state, %{"agent" => name} = ev) when is_binary(name) do
    now = ts(ev, state)

    state =
      put_agent(state, %{get_agent(state, name) | state: :waiting, wait_on: "browse", since: now})

    row(state, ev, %{agent: name, text: "⏸ #{name} waiting on browse"})
  end

  defp fold("browse_done", state, %{"agent" => name} = ev) when is_binary(name) do
    now = ts(ev, state)
    verdict = ev["verdict"] || "?"
    ok? = browse_ok?(verdict)
    ag = get_agent(state, name)
    waiting? = ag.state == :waiting and ag.wait_on == "browse"

    state = bump(state, :browse_total)
    state = if ok?, do: bump(state, :browse_ok), else: state

    state =
      if waiting?,
        do: put_agent(state, %{ag | state: :thinking, wait_on: nil, since: now}),
        else: state

    text =
      if waiting?,
        do: "▶ resumed — browse #{verdict} in #{fmt(now - ag.since)}s",
        else: "▶ browse #{verdict}"

    if ok?,
      do: row(state, ev, %{agent: name, text: text}),
      else: issue_row(state, ev, %{agent: name, text: "⚠ #{text}"})
  end

  defp fold("progress_sent", state, %{"cid" => cid} = ev) when is_binary(cid) do
    state = touch_sent(state, cid, ts(ev, state))
    row(state, ev, %{cid: cid, text: "✉ progress to @#{user(cid)}"})
  end

  defp fold("reply_sent", state, %{"cid" => cid} = ev) when is_binary(cid) do
    now = ts(ev, state)
    ok? = ev["ok"] == true
    ep = state.open[cid]
    # first-feedback means "first thing the user SAW" — a failed delivery showed nothing,
    # so only an ok send may stamp first_sent / sample the KPI
    state = if ok?, do: touch_sent(state, cid, now), else: state

    state =
      cond do
        ok? and ep != nil ->
          close_episode(state, cid, now, ev)

        ok? ->
          # reply to a request opened before our baseline — honest row, no KPI
          row(state, ev, %{cid: cid, text: "✓ @#{user(cid)} replied"})

        true ->
          state
          |> bump(:failures)
          |> issue_row(ev, %{cid: cid, text: "⚠ delivery failed"})
      end

    release_agent(state, ep && ep.agent, now)
  end

  defp fold("reply_failed", state, ev) do
    state = bump(state, :failures)
    issue_row(state, ev, %{text: "⚠ reply dropped (no target)"})
  end

  defp fold("compaction", state, ev) do
    state = bump(state, :compactions)
    row(state, ev, %{text: "☕ compacting context"})
  end

  defp fold("inbox_dropped", state, %{"agent" => name} = ev) when is_binary(name) do
    state = put_agent(state, %{get_agent(state, name) | state: :idle, wait_on: nil, queue: 0})

    issue_row(state, ev, %{
      agent: name,
      text: "⚠ backend died, #{ev["count"] || "?"} task(s) lost"
    })
  end

  # canvas packets only — no story row, no state
  defp fold(kind, state, _ev) when kind in ["typing", "proactive_sent"], do: state

  # synthetic, folded by EventsFeed when a seq gap proves ring pruning
  defp fold("feed_gap", state, ev) do
    state = bump(state, :feed_gaps)
    issue_row(state, ev, %{text: "⚠ feed gap — #{ev["lost"] || "?"} event(s) lost"})
  end

  # synthetic, folded by EventsFeed after a cursor regression (feed restarted)
  defp fold("feed_restart", state, ev) do
    row(state, ev, %{text: "⚠ feed restarted — counters re-baselined"})
  end

  # unknown kind (or a known one missing required fields): generic row only
  defp fold(kind, state, ev) do
    row(state, ev, %{text: "· #{kind || "?"} event"})
  end

  # ── tick passes ───────────────────────────────────────────────────────────────

  defp expire_issues(state, now),
    do: %{state | issues: Enum.reject(state.issues, &(now - &1.ts > @issue_window_s))}

  defp classify_stalled(state, now) do
    threshold = state.stall_after_ms / 1000

    Enum.reduce(state.open, state, fn {cid, ep}, acc ->
      if not ep.stalled and now - ep.opened_at > threshold do
        # dual-ring push like issue_row: ONE classifier feeds the Overview feed,
        # the Events story view, and Sessions badges (spec §5.3)
        r = %{
          seq: nil,
          ts: now,
          kind: "stalled",
          cid: cid,
          agent: ep.agent,
          text: "⚠ stalled — no reply in #{fmt(now - ep.opened_at)}s",
          issue: true
        }

        acc
        |> put_open(%{ep | stalled: true})
        |> bump(:stalled)
        |> push_row(r)
        |> push_issue(r)
      else
        acc
      end
    end)
  end

  # ── episode lifecycle ─────────────────────────────────────────────────────────

  defp new_episode(cid, now) do
    %{
      cid: cid,
      user: user(cid),
      opened_at: now,
      last_open: nil,
      agent: nil,
      count: 1,
      first_sent: nil,
      last_sent: nil,
      done: false,
      done_at: nil,
      status: nil,
      duration: nil,
      stalled: false
    }
  end

  # progress/reply landed: stamp last_sent, and the FIRST one is the
  # first-feedback sample (open → first thing the user saw)
  defp touch_sent(state, cid, now) do
    case state.open[cid] do
      nil ->
        state

      %{first_sent: nil} = ep ->
        state
        |> put_open(%{ep | first_sent: now, last_sent: now})
        |> sample(:first_feedback_durations, now - ep.opened_at)

      ep ->
        put_open(state, %{ep | last_sent: now})
    end
  end

  # EXACT close — the fact "this was the reply" needs no guessing
  defp close_episode(state, cid, now, ev) do
    ep = state.open[cid]
    dur = now - ep.opened_at
    closed = %{ep | done: true, done_at: now, status: "replied", duration: dur}

    if ep.count > 1 and ep.last_open do
      # a queued follow-up is still unanswered: close this leg only and re-arm
      # the request for the next one (keeps the in-flight row anchored)
      rearmed = %{
        ep
        | count: ep.count - 1,
          opened_at: ep.last_open,
          first_sent: nil,
          last_sent: nil,
          stalled: false
      }

      state
      |> push_closed(closed)
      |> put_open(rearmed)
      |> reply_kpi(dur)
      |> row(ev, %{
        cid: cid,
        text: "✓ @#{user(cid)} replied in #{fmt(dur)}s · +#{ep.count - 1} queued"
      })
    else
      state
      |> push_closed(closed)
      |> drop_open(cid)
      |> reply_kpi(dur)
      |> row(ev, %{cid: cid, text: "✓ @#{user(cid)} replied in #{fmt(dur)}s"})
    end
  end

  defp reply_kpi(state, dur) do
    state
    |> bump(:replies)
    |> sample(:reply_durations, dur)
  end

  defp release_agent(state, nil, _now), do: state

  defp release_agent(state, name, now) do
    ag = get_agent(state, name)

    if ag.queue > 0,
      do:
        put_agent(state, %{ag | queue: ag.queue - 1, state: :thinking, wait_on: nil, since: now}),
      else: put_agent(state, %{ag | state: :idle, wait_on: nil})
  end

  # ── state plumbing ────────────────────────────────────────────────────────────

  defp get_agent(state, name) do
    state.agents[name] || %{name: name, state: :idle, wait_on: nil, since: nil, queue: 0}
  end

  defp put_agent(state, ag), do: %{state | agents: Map.put(state.agents, ag.name, ag)}
  defp put_open(state, ep), do: %{state | open: Map.put(state.open, ep.cid, ep)}
  defp drop_open(state, cid), do: %{state | open: Map.delete(state.open, cid)}

  defp push_closed(state, ep),
    do: %{state | closed: Enum.take([ep | state.closed], state.closed_max)}

  defp row(state, ev, attrs), do: push_row(state, build_row(state, ev, attrs))

  defp issue_row(state, ev, attrs) do
    r = build_row(state, ev, Map.put(attrs, :issue, true))
    state |> push_row(r) |> push_issue(r)
  end

  defp build_row(state, ev, attrs) do
    Map.merge(
      %{
        seq: ev["seq"],
        ts: ts(ev, state),
        kind: ev["kind"],
        cid: ev["cid"],
        agent: ev["agent"] || ev["slot"] || ev["from"],
        text: "",
        issue: false
      },
      attrs
    )
  end

  defp push_row(state, r), do: %{state | story: Enum.take([r | state.story], state.story_max)}

  defp push_issue(state, r),
    do: %{state | issues: Enum.take([r | state.issues], state.issues_max)}

  defp bump(state, key),
    do: %{state | counters: Map.update!(state.counters, key, &(&1 + 1))}

  # percentile samples are capped: counters are exact, percentiles recent-windowed
  defp sample(state, key, value) do
    %{
      state
      | counters: Map.update!(state.counters, key, &Enum.take([value | &1], state.samples_max))
    }
  end

  defp ts(ev, state), do: ev["ts"] || state.now || 0.0

  defp user(cid) do
    case String.split(cid, ":") do
      [_, chat, _ | _] -> chat
      _ -> cid
    end
  end

  defp browse_ok?(verdict), do: is_binary(verdict) and String.starts_with?(verdict, "ok")

  defp fmt(dur), do: :erlang.float_to_binary(dur / 1, decimals: 1)
end
