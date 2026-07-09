defmodule SubzeroSwarmDashboardWeb.OverviewLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboard.RouterClient
  alias SubzeroSwarmDashboard.RouterUsageCache
  alias SubzeroSwarmDashboardWeb.DashHooks
  alias SubzeroSwarmDashboardWeb.ReplyHealth

  # The router-usage card refreshes on its own slow pulse — every other card on
  # this page auto-updates, so a mount-once fetch froze visibly.
  @usage_refresh_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load_usage)

    # stale-while-revalidate off the same cache the Usage page fills
    {:ok, assign(socket, usage: RouterUsageCache.get("all") || :loading, page_title: "Overview")}
  end

  @impl true
  def handle_info(:load_usage, socket) do
    result = RouterClient.usage()
    RouterUsageCache.put("all", result)
    Process.send_after(self(), :load_usage, @usage_refresh_ms)
    {:noreply, assign(socket, usage: result)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])

    assigns =
      assign(assigns,
        inspect_lookup: inspect_lookup,
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?),
        warnings: warnings(assigns[:snapshot], privacy?)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:overview}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5 max-w-6xl">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl">Overview</h1>
          <div class="flex items-center gap-2">
            <span
              :if={@snapshot}
              class={["text-xs", (stale?(@snapshot) && "text-warning") || "opacity-60"]}
            >
              updated {snapshot_age(@snapshot)}
            </span>
            <.conn_badge status={@conn_status} snapshot={@snapshot} />
          </div>
        </div>

        <.banner :if={@conn_status == :disconnected} kind="error">
          Swarm unreachable — retrying. Showing the last known snapshot.
        </.banner>
        <.banner :if={@feed_warning == :endpoint_not_colocated} kind="warning">
          The API responds but no live WS events are arriving — the dashboard endpoint may
          not be co-located with the swarm BEAM (see spec §5 C1).
        </.banner>

        <%!-- The live request story (spec §5.6): who is waiting right now, on what,
              for how long. When the feed is down, one honest line replaces the
              panels — the snapshot cards below keep working regardless. --%>
        <div
          :if={@story && @story[:feed_status] != :ok}
          id="story-degraded"
          class="alert alert-warning text-sm"
        >
          live story unavailable — the display-event feed isn't answering; snapshot cards below keep working.
        </div>
        <%= if @story && @story[:feed_status] == :ok do %>
          <.in_flight_panel
            story={@story}
            snapshot={@snapshot}
            privacy={@privacy}
            inspect_lookup={@inspect_lookup}
          />
          <div class="grid lg:grid-cols-2 gap-5">
            <.agents_panel
              story={@story}
              snapshot={@snapshot}
              privacy={@privacy}
              inspect_lookup={@inspect_lookup}
            />
            <.issues_panel story={@story} snapshot={@snapshot} privacy={@privacy} />
          </div>
          <.kpi_panel story={@story} snapshot={@snapshot} />
        <% end %>

        <.panel :if={@snapshot} id="swarm-panel" title="Swarm">
          <div class="grid grid-cols-2 md:grid-cols-5 gap-x-4 gap-y-3">
            <.metric
              label="status"
              value={@snapshot["status"]}
              sub={"uptime " <> fmt_uptime(@snapshot["uptime_s"])}
            />
            <.metric label="data source" value={@snapshot["data_source"]} />
            <.metric label="agents" value={get_in(@snapshot, ["summary", "agents"])} />
            <.metric label="objects" value={get_in(@snapshot, ["summary", "objects"])} />
            <.metric label="consumers" value={consumers_count(@snapshot)} />
          </div>
        </.panel>

        <div :if={@snapshot} class="grid lg:grid-cols-2 gap-5">
          <.panel title="Slot pool">
            <.pool_bar pool={get_in(@snapshot, ["summary", "pool"])} />
          </.panel>
          <.panel title="Usage · router">
            <.usage_summary usage={@usage} />
          </.panel>
        </div>

        <.panel
          :if={@snapshot && @warnings != []}
          title="Warnings"
          class="border-warning/50 bg-warning/5"
        >
          <ul class="text-sm space-y-1">
            <li :for={w <- @warnings} class="font-mono">
              <span class="badge badge-warning badge-sm">{w["code"]}</span>
              {w["object"]} — {w["reason"]}
            </li>
          </ul>
        </.panel>

        <div :if={is_nil(@snapshot)} class="opacity-60">Waiting for the first snapshot…</div>
      </div>
    </Layouts.app>
    """
  end

  # ── story panels (spec §5.6) ─────────────────────────────────────────────────
  attr :story, :map, required: true
  attr :snapshot, :map, default: nil
  attr :privacy, :boolean, default: false
  attr :inspect_lookup, :map, default: %{}

  defp in_flight_panel(assigns) do
    assigns =
      assigns
      |> assign(:eps, assigns.story[:in_flight] || [])
      |> assign(:last, last_close(assigns.story, assigns.privacy))

    ~H"""
    <.panel id="in-flight-panel" title="In flight">
      <:meta>
        <span class="font-mono tnum">{length(@eps)}</span>
        <span class="opacity-60">open</span>
      </:meta>
      <%!-- the most common view: nothing waiting — one reassuring line, not an empty box --%>
      <div :if={@eps == []} id="in-flight-idle" class="text-sm font-mono opacity-70 py-1">
        <span class="text-success">○</span>
        nobody waiting<span :if={@last}> · last: {@last.text} at <.local_time
            id="last-close-t"
            ts={@last.ts}
          /></span>
      </div>
      <div class="divide-y divide-base-300/50">
        <div
          :for={ep <- @eps}
          id={"in-flight-#{dom_cid(ep.cid, @privacy)}"}
          class="flex items-center gap-3 font-mono text-sm py-2 first:pt-0 last:pb-0"
        >
          <%= if @privacy do %>
            <span class="w-36 min-w-0 flex items-center gap-2 font-semibold">
              <.identity_avatar
                user={session_user(@snapshot, ep.cid)}
                session_id={ep.cid}
                label={session_label(@snapshot, ep.cid)}
                privacy={@privacy}
                size={:sm}
              />
              <span class="truncate">•••</span>
            </span>
          <% else %>
            <span class="w-36 truncate font-semibold">
              @{handle_for(@snapshot, ep.cid, ep.user)}
            </span>
          <% end %>
          <span class="w-36 truncate opacity-60">{ep.agent || "routing"}</span>
          <span class={["flex-1 truncate", (ep.stalled && "text-error") || "text-primary"]}>
            {ep.activity}<span
              :if={queued_turns(@story, ep) > 0}
              class="opacity-60"
              title="messages from this user waiting for the current turn to finish"
            > · +{queued_turns(@story, ep)} queued</span>
          </span>
          <span class="tnum whitespace-nowrap">{duration(ep.elapsed_s)}</span>
          <progress
            class={["progress w-24", progress_tone(ep)]}
            value={stall_pct(ep.elapsed_s)}
            max="100"
          />
          <%= if @privacy do %>
            <% inspect_target = inspect_value(@inspect_lookup, true, ep.cid) %>
            <button
              :if={inspect_target}
              type="button"
              phx-click="inspect"
              phx-value-session_id={inspect_target}
              class="link link-hover text-xs opacity-70"
            >
              session
            </button>
          <% else %>
            <.link navigate={session_href(ep.cid)} class="link link-hover text-xs opacity-70">
              session
            </.link>
          <% end %>
        </div>
      </div>
    </.panel>
    """
  end

  attr :story, :map, required: true
  attr :snapshot, :map, default: nil
  attr :privacy, :boolean, default: false
  attr :inspect_lookup, :map, default: %{}

  # User-first: one chip per conversation currently HOLDING an agent (snapshot
  # lease truth), overlaid with the live state the feed knows for that slot.
  # Slot names are fungible pool infrastructure, not identity — they survive
  # only as a tooltip. Unleased idle slots collapse into the pool meta line.
  defp agents_panel(assigns) do
    assigns =
      assigns
      |> assign(:rows, serving_rows(assigns.snapshot, assigns.story))
      |> assign(:pool, get_in(assigns.snapshot || %{}, ["summary", "pool"]))

    ~H"""
    <.panel id="agents-strip" title="Serving">
      <%!-- pool is snapshot truth (existence/leases); "avg backend-up" was cut —
            the feed has no spawn-ready event, so it is not derivable (spec §5.6) --%>
      <:meta>
        <span :if={@pool} class="font-mono">pool {@pool["leased"]}/{@pool["size"]} leased</span>
      </:meta>
      <div class="flex flex-wrap gap-2">
        <.serving_chip
          :for={row <- @rows}
          row={row}
          privacy={@privacy}
          inspect_lookup={@inspect_lookup}
        />
        <span :if={@rows == []} class="text-sm opacity-60 py-1">
          no conversation holds an agent right now — the pool is all idle
        </span>
      </div>
    </.panel>
    """
  end

  attr :row, :map, required: true
  attr :privacy, :boolean, default: false
  attr :inspect_lookup, :map, default: %{}

  defp serving_chip(assigns) do
    assigns =
      assign(assigns, :inspect_target, inspect_value(assigns.inspect_lookup, true, assigns.row.cid))

    ~H"""
    <%= if @privacy do %>
      <button
        type="button"
        id={"serving-#{dom_cid(@row.cid, true)}"}
        phx-click={@inspect_target && "inspect"}
        phx-value-session_id={@inspect_target}
        class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100/60 px-2.5 py-1.5 font-mono text-xs whitespace-nowrap"
      >
        <span class={agent_tone(@row.state)}>{agent_glyph(@row.state)}</span>
        <.identity_avatar
          user={@row.user}
          session_id={@row.cid}
          label={@row.label}
          privacy={@privacy}
          size={:sm}
        />
        <span class="font-semibold">•••</span>
        <span class="opacity-60">{agent_state_label(@row)}</span>
        <span :if={@row.elapsed_s} class="opacity-40 tnum">{duration(@row.elapsed_s)}</span>
        <span :if={@row.queue > 0} class="badge badge-warning badge-xs">+{@row.queue}</span>
      </button>
    <% else %>
      <.link
        navigate={session_href(@row.cid)}
        id={"serving-#{dom_cid(@row.cid, false)}"}
        title={@row.agent && "slot #{@row.agent}"}
        class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100/60 px-2.5 py-1.5 font-mono text-xs whitespace-nowrap hover:border-primary/50"
      >
        <span class={agent_tone(@row.state)}>{agent_glyph(@row.state)}</span>
        <span class="font-semibold">@{@row.who}</span>
        <span class="opacity-60">{agent_state_label(@row)}</span>
        <span :if={@row.elapsed_s} class="opacity-40 tnum">{duration(@row.elapsed_s)}</span>
        <span :if={@row.queue > 0} class="badge badge-warning badge-xs">+{@row.queue}</span>
      </.link>
    <% end %>
    """
  end

  # Leased sessions (snapshot truth: who holds an agent) joined with the feed's
  # per-slot state, plus in-flight episodes whose conversation hasn't reached
  # the snapshot roster yet (first turn) — active first, then queued, then by
  # slot recency.
  defp serving_rows(snapshot, story) do
    slot_state = Map.new(story[:agents] || [], &{&1.name, &1})
    sessions = (is_map(snapshot) && snapshot["sessions"]) || []

    leased =
      for s <- sessions, is_binary(s["agent"]) and s["agent"] != "" do
        ag = slot_state[s["agent"]]

        %{
          cid: s["session_id"],
          who: session_display(s),
          user: s["user"],
          label: s["label"],
          agent: s["agent"],
          state: (ag && ag.state) || :idle,
          wait_on: ag && ag.wait_on,
          queue: (ag && ag.queue) || 0,
          elapsed_s: ag && ag.elapsed_s
        }
      end

    leased_cids = MapSet.new(leased, & &1.cid)

    in_flight =
      for ep <- story[:in_flight] || [],
          is_binary(ep.cid),
          not MapSet.member?(leased_cids, ep.cid) do
        ag = ep.agent && slot_state[ep.agent]

        %{
          cid: ep.cid,
          who: ep.user,
          user: nil,
          label: ep.user,
          agent: ep.agent,
          state: (ag && ag.state) || :thinking,
          wait_on: ag && ag.wait_on,
          queue: (ag && ag.queue) || 0,
          elapsed_s: ep.elapsed_s
        }
      end

    Enum.sort_by(leased ++ in_flight, &{serving_rank(&1.state), -&1.queue, -(&1.elapsed_s || 0)})
  end

  defp serving_rank(:thinking), do: 0
  defp serving_rank(:waiting), do: 1
  defp serving_rank(:spawning), do: 2
  defp serving_rank(_state), do: 3

  # @handle when the roster knows it, else the session label, else the raw chat
  # part of the cid — same fallback ladder the story fold uses.
  defp session_display(s) do
    handle = get_in(s, ["user", "handle"])
    label = s["label"]

    cond do
      is_binary(handle) and handle != "" -> handle
      is_binary(label) and label != "" -> label
      true -> chat_part(s["session_id"])
    end
  end

  defp chat_part(cid) when is_binary(cid) do
    case String.split(cid, ":") do
      [_, chat, _ | _] -> chat
      _ -> cid
    end
  end

  defp chat_part(cid), do: to_string(cid)

  defp agent_tone(:thinking), do: "text-primary"
  defp agent_tone(:waiting), do: "text-warning"
  defp agent_tone(:spawning), do: "text-info"
  defp agent_tone(_state), do: "opacity-40"

  attr :story, :map, required: true
  attr :snapshot, :map, default: nil

  defp kpi_panel(assigns) do
    assigns =
      assigns
      |> assign(:k, assigns.story[:kpis] || %{})
      |> assign(:today, metrics_today(assigns.snapshot))
      |> assign(:inbox_queue, get_in(assigns.snapshot || %{}, ["extensions", "inbox_queue"]))
      |> assign(
        :attention,
        ReplyHealth.counts(assigns.snapshot, assigns.story, System.os_time(:second))
      )

    ~H"""
    <.panel id="kpi-panel" title="Window">
      <%!-- honest window label: counters restart at the dashboard's baseline (spec §9);
            a counter present in extensions["metrics_today"] is durable → "today" badge,
            anything else carries "window" — it dies with the dashboard process --%>
      <:meta>
        <span id="kpi-window-label" class="font-mono">
          since <.local_time id="kpi-since" ts={@story[:baseline_at]} />
        </span>
      </:meta>
      <div class="grid grid-cols-3 md:grid-cols-5 xl:grid-cols-9 gap-x-4 gap-y-3">
        <.link navigate={~p"/sessions"} class="contents">
          <.metric
            label="unanswered"
            value={@attention.unanswered}
            tone={alarm_tone(@attention.unanswered, "warn")}
            title="live conversations whose last user message got NO reply — a stall, not policy. Click for the attention-sorted list."
          />
        </.link>
        <.link navigate={~p"/sessions"} class="contents">
          <.metric
            label="suppressed"
            value={@attention.suppressed}
            title="replies withheld by the sender's spam window — the bot CHOSE silence (policy working, not an outage). Click for the list."
          />
        </.link>
        <.metric
          label="replies"
          value={today_val(@today, "replies") || @k[:replies] || 0}
          badge={(today_val(@today, "replies") && "today") || "window"}
          title="replies delivered. 'today' = the swarm's durable daily counter; 'window' = counted by this dashboard since the baseline above (resets when it restarts)."
        />
        <.metric
          label="p50 reply"
          value={duration(@k[:reply_p50])}
          title="median time from a user's message to the reply landing, over this window"
        />
        <.metric
          label="p95 reply"
          value={duration(@k[:reply_p95])}
          title="95th-percentile reply time — the slow tail users actually feel"
        />
        <.metric
          label="first feedback"
          value={duration(@k[:first_feedback_p50])}
          title="median time until the user SAW anything (typing, progress, reply) after writing"
        />
        <.metric
          label="failures"
          value={today_val(@today, "failures") || @k[:failures] || 0}
          badge={(today_val(@today, "failures") && "today") || "window"}
          tone={alarm_tone(today_val(@today, "failures") || @k[:failures], "error")}
          title="failed deliveries + dropped replies + LLM errors. 'today' = durable daily counter; 'window' = since the baseline above."
        />
        <.metric
          label="inbox full"
          value={today_val(@today, "inbox_full") || @k[:inbox_full] || 0}
          badge={(today_val(@today, "inbox_full") && "today") || "window"}
          tone={alarm_tone(today_val(@today, "inbox_full") || @k[:inbox_full], "warn")}
          title="messages bounced because an agent's mailbox was full — users hitting a busy bot"
        />
        <.metric
          :if={@inbox_queue}
          label="queue"
          value={@inbox_queue["depth"]}
          sub={queue_sub(@inbox_queue)}
          tone={alarm_tone(@inbox_queue["depth"], "warn")}
          title="Messages waiting for a free agent slot — queued, never dropped; drained oldest-first every 20s."
        />
        <.metric
          label="stalled"
          value={@k[:stalled] || 0}
          tone={alarm_tone(@k[:stalled], "warn")}
          title="requests currently past the stall threshold with no reply — live count, not cumulative"
        />
        <.metric
          label="compactions"
          value={today_val(@today, "compactions") || @k[:compactions] || 0}
          badge={(today_val(@today, "compactions") && "today") || "window"}
          title="agent context compactions — normal at low volume; a spike means conversations are running long"
        />
        <.link navigate={~p"/events?#{[issues: 1]}"} class="contents">
          <.metric
            label="browser"
            value={browse_rate(@k)}
            sub={browse_sub(@k)}
            tone={(@k[:browse_blocked] || 0) > 0 && "warn"}
            title="browser fetches this window. 'blocked' = the allowlist said no (policy — fix the list), other failures = rendering broke. Click for the issue events."
          />
        </.link>
      </div>
    </.panel>
    """
  end

  # "2 blocked · 1 failed" under the browser rate — blocked (policy) and broken
  # (render) are different problems with different owners; nil hides the line.
  defp queue_sub(%{"oldest_seconds" => seconds}) when is_number(seconds),
    do: "oldest #{div(trunc(seconds), 60)}m"

  defp queue_sub(_), do: nil

  defp browse_sub(k) do
    total = k[:browse_total] || 0
    ok = k[:browse_ok] || 0
    blocked = k[:browse_blocked] || 0
    failed = max(total - ok - blocked, 0)

    parts =
      [(blocked > 0 && "#{blocked} blocked") || nil, (failed > 0 && "#{failed} failed") || nil]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  attr :story, :map, required: true
  attr :snapshot, :map, default: nil
  attr :privacy, :boolean, default: false

  defp issues_panel(assigns) do
    assigns =
      assign(assigns,
        issues: issues_for_privacy(dedupe_issues(assigns.story[:issues] || []), assigns.privacy),
        who: session_who(assigns.snapshot, assigns.privacy)
      )

    ~H"""
    <.panel id="issues-panel" title="Issues">
      <:meta>
        <span class="font-mono">
          last 24h · observed since <.local_time id="issues-since" ts={@story[:baseline_at]} />
        </span>
      </:meta>
      <div :if={@issues == []} class="text-sm opacity-60 py-1">
        <span class="text-success">✓</span> none observed
      </div>
      <div class="divide-y divide-base-300/50">
        <div
          :for={{issue, i} <- Enum.with_index(@issues)}
          id={"issue-#{i}"}
          class="flex items-baseline gap-3 font-mono text-xs py-1.5 first:pt-0 last:pb-0"
        >
          <span class="opacity-50 whitespace-nowrap">
            <.local_time id={"issue-#{i}-t"} ts={issue.ts} />
          </span>
          <span class="w-28 truncate opacity-70" title={if(@privacy, do: nil, else: issue.cid)}>
            {@who[issue.cid] || issue.cid || issue.agent}
          </span>
          <span class="flex-1 truncate text-warning">
            {issue.text}<span :if={issue.count > 1} class="opacity-60"> ×{issue.count}</span>
          </span>
          <.link
            navigate={issue_href(issue, @privacy)}
            class="link link-hover opacity-70 whitespace-nowrap"
          >
            events →
          </.link>
        </div>
      </div>
    </.panel>
    """
  end

  # Same defect repeating ("browse blocked" every retry) collapses to ONE row
  # carrying the LATEST ts and a ×N count — the operator reads "still happening,
  # N times", not a wall of identical lines. Keyed by (who, text); newest first.
  defp dedupe_issues(issues) do
    issues
    |> Enum.group_by(&{&1.cid || &1.agent, &1.text})
    |> Enum.map(fn {_k, group} ->
      latest = Enum.max_by(group, & &1.ts)
      Map.put(latest, :count, length(group))
    end)
    |> Enum.sort_by(& &1.ts, :desc)
  end

  # cid => "@handle" from the snapshot's sessions — issues name PEOPLE, not
  # transport ids, whenever the join is available (raw cid stays as tooltip).
  defp session_who(nil, _privacy?), do: %{}

  defp session_who(snap, false) do
    for s <- snap["sessions"] || [],
        handle = get_in(s, ["user", "handle"]),
        is_binary(handle) and handle != "",
        into: %{},
        do: {s["session_id"], "@" <> handle}
  end

  defp session_who(snap, true) do
    for s <- snap["sessions"] || [],
        sid = s["session_id"],
        is_binary(sid) and sid != "",
        into: %{},
        do: {sid, "•••"}
  end

  # ── components ───────────────────────────────────────────────────────────────
  attr :status, :atom, required: true
  attr :snapshot, :map, default: nil

  defp conn_badge(assigns) do
    ~H"""
    <span class={[
      "badge",
      @status == :connected && "badge-success",
      @status == :disconnected && "badge-error",
      @status == :connecting && "badge-ghost"
    ]}>
      {@status}
    </span>
    """
  end

  attr :pool, :map, default: nil

  defp pool_bar(assigns) do
    ~H"""
    <div :if={@pool}>
      <div class="flex justify-between text-sm mb-1">
        <span>{@pool["leased"]} leased / {@pool["size"]} slots</span>
        <span class={saturation_class(@pool)}>{saturation_pct(@pool)}%</span>
      </div>
      <progress
        class={["progress", saturation_progress_class(@pool)]}
        value={@pool["leased"]}
        max={@pool["size"]}
      />
      <p :if={saturation_pct(@pool) >= 90} class="text-xs text-error mt-1">
        Pool near saturation — new sessions evict active ones (LRU), dropping live context.
      </p>
    </div>
    <div :if={is_nil(@pool)} class="text-sm opacity-60">pool unavailable (no sessions source)</div>
    """
  end

  attr :kind, :string, required: true
  slot :inner_block, required: true

  defp banner(assigns) do
    ~H"""
    <div class={["alert", @kind == "error" && "alert-error", @kind == "warning" && "alert-warning"]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :usage, :any, required: true

  defp usage_summary(%{usage: {:ok, u}} = assigns) do
    assigns = assign(assigns, :totals, u["totals"] || %{})

    ~H"""
    <div class="text-sm space-y-1">
      <div><b>{num(@totals["tokens_total"] || @totals["total_tokens"])}</b> tokens</div>
      <div>{num(@totals["requests"])} requests · {num(@totals["errors"])} errors</div>
    </div>
    """
  end

  defp usage_summary(assigns) do
    ~H"""
    <div class="text-sm opacity-60">
      {if @usage == :loading, do: "loading…", else: "Usage unavailable"}
    </div>
    """
  end

  # ── story helpers ────────────────────────────────────────────────────────────
  # the idle one-liner reads the freshest successful close out of the story tail
  defp last_close(story, false),
    do: Enum.find(story[:story] || [], &(&1.kind == "reply_sent" and not &1.issue))

  defp last_close(story, true) do
    case last_close(story, false) do
      %{} = row -> Map.update(row, :text, nil, &PrivacyRedactor.mask_text/1)
      other -> other
    end
  end

  defp today_val(nil, _key), do: nil

  defp today_val(today, key) do
    case today[key] do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  # Atom-keyed story KPIs only — the reducer still writes :browse_* here, so
  # there's no legacy/new spelling split at this call site. The durable
  # browse_*/browser_* overlay (string-keyed metrics_today) is handled in
  # usage_live.ex's browse_counts/2; mirror that sum here if overview ever
  # grows its own durable overlay.
  defp browse_rate(k) do
    total = k[:browse_total] || 0
    if total > 0, do: "#{round((k[:browse_ok] || 0) * 100 / total)}% ok", else: "—"
  end

  defp agent_glyph(:thinking), do: "●"
  defp agent_glyph(:waiting), do: "◐"
  defp agent_glyph(:spawning), do: "◌"
  defp agent_glyph(_state), do: "○"

  defp agent_state_label(%{state: :waiting, wait_on: w}), do: "waiting #{w || "?"}"
  defp agent_state_label(ag), do: to_string(ag.state)

  # the bar fills toward the stall threshold — full means about to be flagged stalled
  defp stall_pct(elapsed) when is_number(elapsed) do
    stall_s = Application.get_env(:subzero_swarm_dashboard, :stall_after_ms, 180_000) / 1000
    min(round(elapsed * 100 / stall_s), 100)
  end

  defp stall_pct(_elapsed), do: 0

  defp progress_tone(ep) do
    cond do
      ep.stalled -> "progress-error"
      stall_pct(ep.elapsed_s) >= 60 -> "progress-warning"
      true -> "progress-success"
    end
  end

  defp issue_href(%{cid: cid}, false) when is_binary(cid),
    do: ~p"/events?#{[cid: cid, issues: 1]}"

  defp issue_href(_issue, _privacy?), do: ~p"/events?#{[issues: 1]}"

  defp dom_cid(cid, false), do: String.replace(to_string(cid), ~r/[^A-Za-z0-9_-]/, "-")

  defp dom_cid(cid, true) do
    cid
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  # ── helpers ──────────────────────────────────────────────────────────────────
  defp consumers_count(snap), do: get_in(snap, ["extensions", "consumers", "count"]) || 0

  defp warnings(nil, _privacy?), do: []
  defp warnings(snap, false), do: snap["warnings"] || []

  defp warnings(snap, true) do
    snap
    |> Map.get("warnings", [])
    |> PrivacyRedactor.mask_identity()
    |> Enum.map(fn
      %{} = w ->
        w
        |> Map.update("object", nil, &PrivacyRedactor.mask_cid/1)
        |> Map.update("reason", nil, &PrivacyRedactor.mask_cid/1)

      other ->
        other
    end)
  end

  defp issues_for_privacy(issues, false), do: issues

  defp issues_for_privacy(issues, true) do
    Enum.map(issues, fn
      %{} = issue -> Map.update(issue, :text, nil, &PrivacyRedactor.mask_text/1)
      issue -> issue
    end)
  end

  defp session_user(snapshot, cid) do
    case session_for(snapshot, cid) do
      %{} = session -> session["user"]
      _ -> nil
    end
  end

  defp session_label(snapshot, cid) do
    case session_for(snapshot, cid) do
      %{} = session -> session["label"]
      _ -> nil
    end
  end

  defp session_for(%{"sessions" => sessions}, cid) when is_list(sessions),
    do: Enum.find(sessions, &(&1["session_id"] == cid))

  defp session_for(_snapshot, _cid), do: nil

  defp inspect_value(lookup, privacy?, sid),
    do: DashHooks.inspect_value(lookup, privacy? == true, sid)

  # Staleness from the server-side snapshot time (spec §12).
  defp snapshot_age(snap) do
    case parse_dt(snap["generated_at"]) do
      {:ok, dt} -> "#{max(DateTime.diff(DateTime.utc_now(), dt), 0)}s ago"
      _ -> "—"
    end
  end

  defp stale?(snap) do
    case parse_dt(snap["generated_at"]) do
      {:ok, dt} -> DateTime.diff(DateTime.utc_now(), dt) > 10
      _ -> false
    end
  end

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_dt(_), do: :error

  defp fmt_uptime(nil), do: "—"

  defp fmt_uptime(s) when is_integer(s) do
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    "#{h}h #{m}m"
  end

  defp fmt_uptime(_), do: "—"

  defp saturation_pct(%{"leased" => l, "size" => s})
       when is_integer(l) and is_integer(s) and s > 0,
       do: round(l * 100 / s)

  defp saturation_pct(_), do: 0

  defp saturation_class(pool) do
    cond do
      saturation_pct(pool) >= 90 -> "text-error font-bold"
      saturation_pct(pool) >= 70 -> "text-warning"
      true -> "opacity-60"
    end
  end

  defp saturation_progress_class(pool) do
    cond do
      saturation_pct(pool) >= 90 -> "progress-error"
      saturation_pct(pool) >= 70 -> "progress-warning"
      true -> "progress-success"
    end
  end
end
