defmodule SubzeroSwarmDashboardWeb.OverviewLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.RouterClient

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load_usage)
    {:ok, assign(socket, usage: :loading, page_title: "Overview")}
  end

  @impl true
  def handle_info(:load_usage, socket) do
    {:noreply, assign(socket, usage: RouterClient.usage())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:overview}
      swarm={@swarm}
      snapshot={@snapshot}
      story={@story}
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
          <.in_flight_panel story={@story} snapshot={@snapshot} />
          <div class="grid lg:grid-cols-2 gap-5">
            <.agents_panel story={@story} snapshot={@snapshot} />
            <.issues_panel story={@story} />
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
          :if={@snapshot && @snapshot["warnings"] != []}
          title="Warnings"
          class="border-warning/50 bg-warning/5"
        >
          <ul class="text-sm space-y-1">
            <li :for={w <- @snapshot["warnings"]} class="font-mono">
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

  defp in_flight_panel(assigns) do
    assigns =
      assigns
      |> assign(:eps, assigns.story[:in_flight] || [])
      |> assign(:last, last_close(assigns.story))

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
          id={"in-flight-#{dom_cid(ep.cid)}"}
          class="flex items-center gap-3 font-mono text-sm py-2 first:pt-0 last:pb-0"
        >
          <span class="w-36 truncate font-semibold">
            @{handle_for(@snapshot, ep.cid, ep.user)}<span
              :if={ep.count > 1}
              class="opacity-60 font-normal"
            > ·+{ep.count - 1}</span>
          </span>
          <span class="w-36 truncate opacity-60">{ep.agent || "routing"}</span>
          <span class={["flex-1 truncate", (ep.stalled && "text-error") || "text-primary"]}>
            {ep.activity}{queue_note(@story, ep.agent)}
          </span>
          <span class="tnum whitespace-nowrap">{duration(ep.elapsed_s)}</span>
          <progress
            class={["progress w-24", progress_tone(ep)]}
            value={stall_pct(ep.elapsed_s)}
            max="100"
          />
          <.link navigate={session_href(ep.cid)} class="link link-hover text-xs opacity-70">
            session
          </.link>
        </div>
      </div>
    </.panel>
    """
  end

  attr :story, :map, required: true
  attr :snapshot, :map, default: nil

  defp agents_panel(assigns) do
    assigns =
      assigns
      |> assign(:agents, assigns.story[:agents] || [])
      |> assign(:pool, get_in(assigns.snapshot || %{}, ["summary", "pool"]))

    ~H"""
    <.panel id="agents-strip" title="Agents">
      <%!-- pool is snapshot truth (existence/leases); "avg backend-up" was cut —
            the feed has no spawn-ready event, so it is not derivable (spec §5.6) --%>
      <:meta>
        <span :if={@pool} class="font-mono">pool {@pool["leased"]}/{@pool["size"]} leased</span>
      </:meta>
      <div class="flex flex-wrap gap-2">
        <span
          :for={ag <- @agents}
          class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100/60 px-2.5 py-1.5 font-mono text-xs whitespace-nowrap"
        >
          <span class={agent_tone(ag.state)}>{agent_glyph(ag.state)}</span>
          <span class="font-semibold">{ag.name}</span>
          <span class="opacity-60">{agent_state_label(ag)}</span>
          <span class="opacity-40 tnum">{duration(ag.elapsed_s)}</span>
          <span :if={ag.queue > 0} class="badge badge-warning badge-xs">+{ag.queue}</span>
        </span>
        <span :if={@agents == []} class="text-sm opacity-60 py-1">
          no agent activity observed yet
        </span>
      </div>
    </.panel>
    """
  end

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

    ~H"""
    <.panel id="kpi-panel" title="Window">
      <%!-- honest window label: counters restart at the dashboard's baseline (spec §9);
            a counter present in extensions["metrics_today"] is durable → "today" badge --%>
      <:meta>
        <span id="kpi-window-label" class="font-mono">
          since <.local_time id="kpi-since" ts={@story[:baseline_at]} />
        </span>
      </:meta>
      <div class="grid grid-cols-3 md:grid-cols-5 xl:grid-cols-9 gap-x-4 gap-y-3">
        <.metric
          label="replies"
          value={today_val(@today, "replies") || @k[:replies] || 0}
          badge={today_val(@today, "replies") && "today"}
        />
        <.metric label="p50 reply" value={duration(@k[:reply_p50])} />
        <.metric label="p95 reply" value={duration(@k[:reply_p95])} />
        <.metric label="first feedback" value={duration(@k[:first_feedback_p50])} />
        <.metric
          label="failures"
          value={today_val(@today, "failures") || @k[:failures] || 0}
          badge={today_val(@today, "failures") && "today"}
          tone={alarm_tone(today_val(@today, "failures") || @k[:failures], "error")}
        />
        <.metric
          label="inbox full"
          value={today_val(@today, "inbox_full") || @k[:inbox_full] || 0}
          badge={today_val(@today, "inbox_full") && "today"}
          tone={alarm_tone(today_val(@today, "inbox_full") || @k[:inbox_full], "warn")}
        />
        <.metric
          label="stalled"
          value={@k[:stalled] || 0}
          tone={alarm_tone(@k[:stalled], "warn")}
        />
        <.metric
          label="compactions"
          value={today_val(@today, "compactions") || @k[:compactions] || 0}
          badge={today_val(@today, "compactions") && "today"}
        />
        <.metric label="browse" value={browse_rate(@k)} />
      </div>
    </.panel>
    """
  end

  # a counter's number is only colored when it IS the alarm (nonzero)
  defp alarm_tone(n, tone) when is_number(n) and n > 0, do: tone
  defp alarm_tone(_n, _tone), do: nil

  attr :story, :map, required: true

  defp issues_panel(assigns) do
    assigns = assign(assigns, :issues, assigns.story[:issues] || [])

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
          <span class="w-28 truncate opacity-70">{issue.cid || issue.agent}</span>
          <span class="flex-1 truncate text-warning">{issue.text}</span>
          <.link navigate={issue_href(issue)} class="link link-hover opacity-70 whitespace-nowrap">
            events →
          </.link>
        </div>
      </div>
    </.panel>
    """
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
      <div><b>{@totals["total_tokens"] || 0}</b> tokens</div>
      <div>{@totals["requests"] || 0} requests · {@totals["errors"] || 0} errors</div>
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
  defp last_close(story),
    do: Enum.find(story[:story] || [], &(&1.kind == "reply_sent" and not &1.issue))

  defp queue_note(story, agent) do
    q = Enum.find_value(story[:agents] || [], 0, &(&1.name == agent and &1.queue))
    if is_integer(q) and q > 0, do: " (#{q} queued)", else: ""
  end

  # join the snapshot's session → user handle (events only carry the cid)
  defp handle_for(snap, cid, fallback) do
    sessions = (is_map(snap) && snap["sessions"]) || []

    with %{} = s <- Enum.find(sessions, &(&1["session_id"] == cid)),
         h when is_binary(h) and h != "" <- get_in(s, ["user", "handle"]) do
      h
    else
      _ -> fallback
    end
  end

  defp metrics_today(snap) do
    case get_in(snap || %{}, ["extensions", "metrics_today"]) do
      %{} = m -> m
      _ -> nil
    end
  end

  defp today_val(nil, _key), do: nil

  defp today_val(today, key) do
    case today[key] do
      n when is_number(n) -> n
      _ -> nil
    end
  end

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

  defp issue_href(%{cid: cid}) when is_binary(cid), do: ~p"/events?#{[cid: cid, issues: 1]}"
  defp issue_href(_issue), do: ~p"/events?#{[issues: 1]}"

  defp dom_cid(cid), do: String.replace(to_string(cid), ~r/[^A-Za-z0-9_-]/, "-")

  # ── helpers ──────────────────────────────────────────────────────────────────
  defp consumers_count(snap), do: get_in(snap, ["extensions", "consumers", "count"]) || 0

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
