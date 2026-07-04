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
  # A stalled episode this many stall-thresholds old is ABANDONED: the reply is
  # never coming (the stall issue row already told the story), so keeping it in
  # `open` pins a red In-Flight row forever and leaks the map. 10 × the default
  # 180s threshold = 30 minutes.
  @abandon_after_multiple 10
  # The agents map is fed by dynamic slot names and never forgets on its own;
  # cap it so a churning pool can't grow the strip (and the per-tick sort/render)
  # without bound. Only long-idle slots are pruned, oldest first.
  @agents_max 32

  @doc "Fold one event (string-keyed, exactly as decoded from JSON). Total."
  def apply(%State{} = state, %{"kind" => kind} = ev), do: fold(kind, state, ev)
  def apply(%State{} = state, ev) when is_map(ev), do: fold(nil, state, ev)

  @doc """
  Wall-clock pass, run on every poll tick: refreshes the in-flight clock,
  classifies stalled episodes (exactly once each), abandons episodes whose reply
  is provably never coming, expires the 24h issue window.
  """
  def tick(%State{} = state, now) do
    %{state | now: now}
    |> expire_issues(now)
    |> classify_stalled(now)
    |> abandon_lost(now)
    |> decay_agents(now)
    |> prune_agents()
  end

  @doc """
  Refresh the cid → @handle map from a `/dashboard` snapshot. Events carry only
  the cid, so this is how the story fold learns who a conversation belongs to;
  `user/2` reads it. Newly-baked rows pick up the handle; rows already folded
  keep whatever was known when they were written (the fold is append-only).
  """
  def put_users(%State{} = state, users) when is_map(users) do
    state = %{state | users: users}
    # Re-stamp OPEN episodes so a first-turn conversation whose request_open was
    # folded before its first snapshot (ep.user baked as the chat id) picks up the
    # @handle now. Topology renders ep.user raw, so without this it would lag
    # Overview (which re-resolves at render) until the episode closed.
    %{
      state
      | open: Map.new(state.open, fn {cid, ep} -> {cid, %{ep | user: user(state, cid)}} end)
    }
  end

  # ── kind → fold (lifecycle vocabulary identical to the prototype) ────────────

  defp fold("request_open", state, %{"cid" => cid} = ev) when is_binary(cid) do
    now = ts(ev, state)

    state =
      case state.open[cid] do
        # More messages while a request is open: track recency, but do NOT
        # count a leg — ingress coalesces a burst into ONE agent turn, and one
        # reply settles it. Counting per-message made a 6-message burst demand
        # 6 replies: 3 comprehensive replies left count=3 → false "stalled" +
        # a forever-red In-Flight row (live 2026-07-04). A leg is a ROUTED
        # turn while the agent is mid-turn (see fold("routed")), because
        # that's the unit the sender actually answers.
        %{} = ep -> put_open(state, %{ep | last_open: now})
        nil -> put_open(state, new_episode(state, cid, now))
      end

    row(state, ev, %{cid: cid, text: "▶ @#{user(state, cid)} request open"})
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

    # A delivery landing while the agent is MID-TURN (thinking/waiting) is a
    # genuinely queued turn — the one unit that will get its own reply, so it
    # counts as a leg for close_episode's re-arm. A delivery to an idle or
    # still-spawning agent is that episode's FIRST turn, never an extra leg.
    state =
      if ep && ag.state in [:thinking, :waiting] do
        put_open(state, %{state.open[cid] | count: state.open[cid].count + 1})
      else
        state
      end

    state =
      if busy?,
        do: put_agent(state, %{ag | queue: min(ag.queue + 1, 99), last_act: now}),
        else: put_agent(state, %{ag | state: :thinking, wait_on: nil, since: now, last_act: now})

    if ep do
      note =
        cond do
          ag.state == :spawning -> "queued while spawning"
          busy? -> "queued behind current turn"
          true -> "claims #{cid}"
        end

      row(state, ev, %{cid: cid, agent: slot, text: "⟳ #{slot} #{note}"})
    else
      state
    end
  end

  defp fold("spawn_start", state, %{"slot" => slot} = ev) when is_binary(slot) do
    now = ts(ev, state)

    state =
      put_agent(state, %{
        get_agent(state, slot)
        | state: :spawning,
          wait_on: nil,
          since: now,
          last_act: now
      })

    row(state, ev, %{agent: slot, text: "⚙ #{slot} spawning"})
  end

  defp fold("teardown", state, %{"slot" => slot} = ev) when is_binary(slot) do
    state = put_agent(state, %{get_agent(state, slot) | state: :idle, wait_on: nil, queue: 0})
    cid = ev["cid"]

    # A teardown carries the cid whose agent was torn down (e.g. H2 healing a dead
    # agent mid-request). If that conversation still has an OPEN request, the turn was
    # DROPPED, not stalled — close it and surface it as an issue so it can't age past
    # stall_after_ms and masquerade as a generic stall (the host already logged
    # "no reply delivered: agent unavailable" for it).
    if is_binary(cid) and Map.has_key?(state.open, cid) do
      state
      |> drop_open(cid)
      |> issue_row(ev, %{
        cid: cid,
        agent: slot,
        text: "✖ @#{user(state, cid)} dropped — agent torn down"
      })
    else
      row(state, ev, %{agent: slot, text: "✖ #{slot} torn down"})
    end
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
    state = put_agent(state, %{ag | state: :thinking, wait_on: nil, since: since, last_act: now})
    state = bump(state, :asks)
    row(state, ev, %{agent: from, text: "⇄ #{from} asked policy"})
  end

  # Renamed kinds (browse→browser). Delegate to the legacy folds so counters/story
  # stay identical during the cutover; drop the browse_* heads a release later.
  defp fold("browser_dispatch", state, ev), do: fold("browse_dispatch", state, ev)
  defp fold("browser_done", state, ev), do: fold("browse_done", state, ev)

  defp fold("browse_dispatch", state, %{"agent" => name} = ev) when is_binary(name) do
    now = ts(ev, state)

    state =
      put_agent(state, %{
        get_agent(state, name)
        | state: :waiting,
          wait_on: "browse",
          since: now,
          last_act: now
      })

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
        do: put_agent(state, %{ag | state: :thinking, wait_on: nil, since: now, last_act: now}),
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
    row(state, ev, %{cid: cid, text: "✉ progress to @#{user(state, cid)}"})
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
          row(state, ev, %{cid: cid, text: "✓ @#{user(state, cid)} replied"})

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

  # spam-window suppress (DeliveryEffects hook, telegram pkg ≥ 0.3.1): the bot
  # chose silence — informational row, not an issue (suppression is the guard
  # working, not a failure)
  defp fold("reply_suppressed", state, ev) do
    row(state, ev, %{cid: ev["cid"], text: "🤫 reply suppressed (spam window)"})
  end

  # agent LLM failure, classified by LlmErrorNotifier (max_turns / api / …)
  defp fold("llm_error", state, ev) do
    state = bump(state, :failures)
    issue_row(state, ev, %{cid: ev["cid"], text: "⚠ LLM error (#{ev["class"] || "?"})"})
  end

  # llm-proxy quota block: a user (or the whole service) hit a spending wall —
  # always an issue row; the reason names which wall
  defp fold("llm_proxy_block", state, ev) do
    issue_row(state, ev, %{cid: ev["cid"], text: "⛔ LLM blocked (#{ev["reason"] || "?"} cap)"})
  end

  # llm-proxy budget store degraded (failing open to the in-memory mirror)
  defp fold("llm_proxy_degraded", state, ev) do
    issue_row(state, ev, %{cid: ev["cid"], text: "⚠ LLM budget store degraded (#{ev["path"] || "?"})"})
  end

  # scheduled job finished: ok-runs fire every few minutes — canvas-level only
  # (no story row, like typing/chatter); anything else IS the story
  defp fold("job_run", state, %{"status" => "ok"} = _ev), do: state

  defp fold("job_run", state, ev) do
    issue_row(state, ev, %{
      text: "⚠ cron #{ev["name"] || "?"} → #{ev["status"] || "?"}"
    })
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

  # canvas packets only — no story row, no state (chatter fires on every metrics
  # bump; a story row per bump would drown the ring)
  defp fold(kind, state, _ev) when kind in ["typing", "proactive_sent", "chatter"], do: state

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

  # A stalled episode that outlives @abandon_after_multiple stall-thresholds is
  # closed as "abandoned": the stall was already surfaced as an issue when it
  # was classified, so this is a story row only — it explains why the row left
  # In-Flight without claiming a reply ever happened.
  defp abandon_lost(state, now) do
    horizon = state.stall_after_ms / 1000 * @abandon_after_multiple

    {lost, kept} = Enum.split_with(state.open, fn {_cid, ep} -> now - ep.opened_at > horizon end)

    Enum.reduce(lost, %{state | open: Map.new(kept)}, fn {cid, ep}, acc ->
      dur = now - ep.opened_at
      closed = %{ep | done: true, done_at: now, status: "abandoned", duration: dur}

      acc
      |> push_closed(closed)
      |> push_row(%{
        seq: nil,
        ts: now,
        kind: "abandoned",
        cid: cid,
        agent: ep.agent,
        text: "✖ @#{ep.user} abandoned — no reply after #{fmt(dur)}s",
        issue: false
      })
    end)
  end

  # Turn-end is invisible to the feed (the engine emits no turn-complete — that's
  # Proposal C, upstream), so an agent that acted after its reply (a post-send ask)
  # would stay "thinking" forever. Honesty rule: stop claiming activity we can't
  # evidence — thinking decays to idle after think_decay_ms without ANY event from
  # that agent; waiting likewise (a lost browse_done) after the longer
  # wait_decay_ms. Decay is silent (no story row — we never claim "turn ended",
  # we just stop claiming "thinking"); since resets to the last evidence.
  defp decay_agents(state, now) do
    Enum.reduce(state.agents, state, fn {_name, ag}, acc ->
      quiet_s = now - (ag.last_act || now)

      cond do
        ag.state == :thinking and quiet_s > state.think_decay_ms / 1000 ->
          put_agent(acc, %{ag | state: :idle, wait_on: nil, since: ag.last_act, queue: 0})

        ag.state == :waiting and quiet_s > state.wait_decay_ms / 1000 ->
          put_agent(acc, %{ag | state: :idle, wait_on: nil, since: ag.last_act, queue: 0})

        true ->
          acc
      end
    end)
  end

  # Bound the agents map: beyond @agents_max, drop the longest-idle slots that
  # owe nothing (idle, empty queue). A static pool never crosses the cap, so the
  # strip keeps showing its idle slots; only dynamic-name churn is forgotten.
  defp prune_agents(%{agents: agents} = state) when map_size(agents) <= @agents_max, do: state

  defp prune_agents(state) do
    prunable =
      state.agents
      |> Map.values()
      |> Enum.filter(&(&1.state == :idle and &1.queue == 0))
      |> Enum.sort_by(&(&1.last_act || 0.0))
      |> Enum.take(map_size(state.agents) - @agents_max)
      |> MapSet.new(& &1.name)

    %{state | agents: Map.reject(state.agents, fn {name, _ag} -> name in prunable end)}
  end

  # ── episode lifecycle ─────────────────────────────────────────────────────────

  defp new_episode(state, cid, now) do
    %{
      cid: cid,
      user: user(state, cid),
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
        text: "✓ @#{user(state, cid)} replied in #{fmt(dur)}s · +#{ep.count - 1} queued"
      })
    else
      state
      |> push_closed(closed)
      |> drop_open(cid)
      |> reply_kpi(dur)
      |> row(ev, %{cid: cid, text: "✓ @#{user(state, cid)} replied in #{fmt(dur)}s"})
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
        put_agent(state, %{
          ag
          | queue: ag.queue - 1,
            state: :thinking,
            wait_on: nil,
            since: now,
            last_act: now
        }),
      else: put_agent(state, %{ag | state: :idle, wait_on: nil, last_act: now})
  end

  # ── state plumbing ────────────────────────────────────────────────────────────

  defp get_agent(state, name) do
    state.agents[name] ||
      %{name: name, state: :idle, wait_on: nil, since: nil, last_act: nil, queue: 0}
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

  # Display label for a conversation: the adapter-provided label/handle when the
  # snapshot knew it (put_users/2), else the raw chat id sliced from the cid —
  # a live session not yet folded into the durable roster still renders.
  defp user(%State{users: users}, cid) do
    case Map.get(users, cid) do
      handle when is_binary(handle) and handle != "" -> handle
      _ -> chat_id(cid)
    end
  end

  defp chat_id(cid) do
    case String.split(cid, ":") do
      [_, chat, _ | _] -> chat
      _ -> cid
    end
  end

  defp browse_ok?(verdict), do: is_binary(verdict) and String.starts_with?(verdict, "ok")

  defp fmt(dur), do: :erlang.float_to_binary(dur / 1, decimals: 1)
end
