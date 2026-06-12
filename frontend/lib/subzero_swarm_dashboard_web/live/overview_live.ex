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
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-6 max-w-5xl">
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
          <.agents_panel story={@story} snapshot={@snapshot} />
          <.kpi_panel story={@story} snapshot={@snapshot} />
          <.issues_panel story={@story} />
        <% end %>

        <div :if={@snapshot} class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.stat
            label="Status"
            value={@snapshot["status"]}
            sub={"uptime " <> fmt_uptime(@snapshot["uptime_s"])}
          />
          <.stat label="Data source" value={@snapshot["data_source"]} />
          <.stat label="Agents" value={get_in(@snapshot, ["summary", "agents"])} />
          <.stat label="Objects" value={get_in(@snapshot, ["summary", "objects"])} />
        </div>

        <div :if={@snapshot} class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Slot pool</h2>
          <.pool_bar pool={get_in(@snapshot, ["summary", "pool"])} />
        </div>

        <div :if={@snapshot} class="grid grid-cols-2 gap-4">
          <div class="card bg-base-200 p-4">
            <h2 class="font-semibold mb-2">Consumers</h2>
            <div class="text-2xl font-bold">{consumers_count(@snapshot)}</div>
          </div>
          <div class="card bg-base-200 p-4">
            <h2 class="font-semibold mb-2">Usage (router)</h2>
            <.usage_summary usage={@usage} />
          </div>
        </div>

        <div
          :if={@snapshot && @snapshot["warnings"] != []}
          class="card bg-warning/10 border border-warning p-4"
        >
          <h2 class="font-semibold mb-2">Warnings</h2>
          <ul class="text-sm space-y-1">
            <li :for={w <- @snapshot["warnings"]} class="font-mono">
              <span class="badge badge-warning badge-sm">{w["code"]}</span>
              {w["object"]} — {w["reason"]}
            </li>
          </ul>
        </div>

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
    <div id="in-flight-panel" class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">In flight ({length(@eps)})</h2>
      <%!-- the most common view: nothing waiting — one reassuring line, not an empty box --%>
      <div :if={@eps == []} id="in-flight-idle" class="text-sm font-mono opacity-70">
        nobody waiting<span :if={@last}> · last: {@last.text} at {hhmm_ts(@last.ts)}</span>
      </div>
      <div class="space-y-1.5">
        <div
          :for={ep <- @eps}
          id={"in-flight-#{dom_cid(ep.cid)}"}
          class="flex items-center gap-3 font-mono text-sm"
        >
          <span class="w-36 truncate">
            @{handle_for(@snapshot, ep.cid, ep.user)}<span :if={ep.count > 1} class="opacity-60"> ·+{ep.count - 1}</span>
          </span>
          <span class="w-36 truncate opacity-80">{ep.agent || "routing"}</span>
          <span class={["flex-1 truncate", ep.stalled && "text-error"]}>
            {ep.activity}{queue_note(@story, ep.agent)}
          </span>
          <span class="tnum whitespace-nowrap">{fmt_s(ep.elapsed_s)}</span>
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
    </div>
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
    <div id="agents-strip" class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">Agents</h2>
      <div class="flex flex-wrap gap-x-6 gap-y-1 font-mono text-sm">
        <span :for={ag <- @agents} class="whitespace-nowrap">
          {ag.name} {agent_glyph(ag.state)} {agent_state_label(ag)}
          <span class="opacity-60">{fmt_s(ag.elapsed_s)}</span>
          <span :if={ag.queue > 0} class="badge badge-ghost badge-xs align-middle">+{ag.queue}</span>
        </span>
        <span :if={@agents == []} class="opacity-60">no agent activity observed yet</span>
      </div>
      <%!-- pool is snapshot truth (existence/leases); "avg backend-up" was cut —
            the feed has no spawn-ready event, so it is not derivable (spec §5.6) --%>
      <div :if={@pool} class="text-xs font-mono opacity-60 mt-2">
        pool {@pool["leased"]}/{@pool["size"]} leased
      </div>
    </div>
    """
  end

  attr :story, :map, required: true
  attr :snapshot, :map, default: nil

  defp kpi_panel(assigns) do
    assigns =
      assigns
      |> assign(:k, assigns.story[:kpis] || %{})
      |> assign(:today, metrics_today(assigns.snapshot))

    ~H"""
    <div id="kpi-panel" class="card bg-base-200 p-4">
      <%!-- honest window label: counters restart at the dashboard's baseline (spec §9);
            a counter present in extensions["metrics_today"] is durable → "today" badge --%>
      <h2 id="kpi-window-label" class="font-semibold mb-2">since {hhmm(@story[:baseline_at])}</h2>
      <div class="flex flex-wrap gap-x-6 gap-y-1 font-mono text-sm">
        <.kpi label="replies" value={@k[:replies]} today={today_val(@today, "replies")} />
        <.kpi label="p50" value={fmt_dur(@k[:reply_p50])} />
        <.kpi label="p95" value={fmt_dur(@k[:reply_p95])} />
        <.kpi label="first-feedback p50" value={fmt_dur(@k[:first_feedback_p50])} />
        <.kpi label="failures" value={@k[:failures]} today={today_val(@today, "failures")} />
        <.kpi label="inbox_full" value={@k[:inbox_full]} today={today_val(@today, "inbox_full")} />
        <.kpi label="stalled" value={@k[:stalled]} />
        <.kpi label="compactions" value={@k[:compactions]} today={today_val(@today, "compactions")} />
        <.kpi label="browse" value={browse_rate(@k)} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :today, :any, default: nil

  defp kpi(assigns) do
    ~H"""
    <span class="whitespace-nowrap">
      <span class="opacity-60">{@label}</span>
      <b class="tnum">{if @today != nil, do: @today, else: @value || 0}</b>
      <span :if={@today != nil} class="badge badge-ghost badge-xs align-middle">today</span>
    </span>
    """
  end

  attr :story, :map, required: true

  defp issues_panel(assigns) do
    assigns = assign(assigns, :issues, assigns.story[:issues] || [])

    ~H"""
    <div id="issues-panel" class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">
        Issues
        <span class="text-xs font-normal opacity-60">
          last 24h · observed since {hhmm(@story[:baseline_at])}
        </span>
      </h2>
      <div :if={@issues == []} class="text-sm opacity-60">none observed</div>
      <div class="space-y-0.5">
        <div
          :for={{issue, i} <- Enum.with_index(@issues)}
          id={"issue-#{i}"}
          class="flex items-baseline gap-3 font-mono text-xs"
        >
          <span class="opacity-50 whitespace-nowrap">{hhmm_ts(issue.ts)}</span>
          <span class="w-28 truncate opacity-70">{issue.cid || issue.agent}</span>
          <span class="flex-1 truncate text-warning">{issue.text}</span>
          <.link navigate={issue_href(issue)} class="link link-hover opacity-70 whitespace-nowrap">
            events →
          </.link>
        </div>
      </div>
    </div>
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

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="text-xs uppercase opacity-60">{@label}</div>
      <div class="text-2xl font-bold">{@value}</div>
      <div :if={@sub} class="text-xs opacity-60">{@sub}</div>
    </div>
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

  # cids carry colons (tg:<chat>:<thread>) — encode like SessionsLive does
  defp session_href(cid), do: ~p"/sessions/#{Base.url_encode64(cid, padding: false)}"

  defp issue_href(%{cid: cid}) when is_binary(cid), do: ~p"/events?#{[cid: cid, issues: 1]}"
  defp issue_href(_issue), do: ~p"/events?#{[issues: 1]}"

  defp dom_cid(cid), do: String.replace(to_string(cid), ~r/[^A-Za-z0-9_-]/, "-")

  defp hhmm(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp hhmm(_dt), do: "—"

  defp hhmm_ts(ts) when is_number(ts),
    do: ts |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%H:%M")

  defp hhmm_ts(_ts), do: "—"

  defp fmt_s(s) when is_number(s) and s < 60, do: "#{Float.round(s / 1, 1)}s"
  defp fmt_s(s) when is_number(s), do: "#{div(trunc(s), 60)}m #{rem(trunc(s), 60)}s"
  defp fmt_s(_s), do: "—"

  defp fmt_dur(v) when is_number(v), do: "#{Float.round(v / 1, 1)}s"
  defp fmt_dur(_v), do: "—"

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
