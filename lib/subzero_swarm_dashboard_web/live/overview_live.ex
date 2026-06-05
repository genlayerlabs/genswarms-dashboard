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
    <Layouts.app flash={@flash} active={:overview} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript} inspect_activity={@inspect_activity}>
      <div class="space-y-6 max-w-5xl">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl">Overview</h1>
          <div class="flex items-center gap-2">
            <span :if={@snapshot} class={["text-xs", stale?(@snapshot) && "text-warning" || "opacity-60"]}>
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

        <div :if={@snapshot} class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.stat label="Status" value={@snapshot["status"]} sub={"uptime " <> fmt_uptime(@snapshot["uptime_s"])} />
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

        <div :if={@snapshot && @snapshot["warnings"] != []} class="card bg-warning/10 border border-warning p-4">
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
      <progress class={["progress", saturation_progress_class(@pool)]} value={@pool["leased"]} max={@pool["size"]} />
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

  defp saturation_pct(%{"leased" => l, "size" => s}) when is_integer(l) and is_integer(s) and s > 0,
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
