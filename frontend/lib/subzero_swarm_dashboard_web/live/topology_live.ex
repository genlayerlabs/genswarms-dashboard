defmodule SubzeroSwarmDashboardWeb.TopologyLive do
  use SubzeroSwarmDashboardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    layout = Application.get_env(:subzero_swarm_dashboard, :pipeline_layout, %{})

    {:ok,
     socket
     |> assign(page_title: "Topology", debug: false)
     |> push_event("pipeline:init", layout)}
  end

  # ?debug=1 shows the hook's trace rig. The hook el is phx-update="ignore", so
  # data-debug is read once AT MOUNT — the param arrives with the page load.
  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, debug: params["debug"] == "1")}

  @impl true
  # Raw display events drive the canvas; the hook owns playback timing (causal).
  def handle_info({:display_event, ev}, socket),
    do: {:noreply, push_event(socket, "pipeline:event", ev)}

  # Agent nodes are dynamic. Precedence (spec §5.5): the snapshot wins existence
  # (which slots are in the pool), the event story wins activity state.
  def handle_info({:snapshot, snap}, socket),
    do: {:noreply, push_event(socket, "pipeline:agents", %{agents: agent_names(snap)})}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:nodes, table_nodes(assigns[:snapshot]))
      |> assign(:gauge, pool_meta(assigns[:snapshot]))
      |> assign(:in_flight, (assigns[:story] && assigns.story[:in_flight]) || [])

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:topology}
      swarm={@swarm}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h1 class="text-2xl">Topology</h1>
          <div
            :if={@gauge.ok}
            class="flex items-center gap-1.5"
            title={"pool #{@gauge.leased} of #{@gauge.size} leased"}
          >
            <div
              class="radial-progress tnum text-[0.6rem]"
              style={"--value:#{@gauge.pct}; --size:2.4rem; --thickness:3px; color:#{@gauge.tone}"}
              role="progressbar"
            >
              <span class="text-base-content">{@gauge.leased}/{@gauge.size}</span>
            </div>
            <span class="text-xs opacity-60">pool</span>
          </div>
        </div>

        <div
          id="pipeline"
          phx-hook="Pipeline"
          phx-update="ignore"
          data-debug={@debug && "1"}
          class="w-full h-[64vh] rounded-box border border-base-300 bg-base-100 relative overflow-hidden"
        >
        </div>

        <div
          id="pipeline-legend"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs opacity-70"
        >
          <span><span class="text-success">●</span> thinking</span>
          <span>
            <span class="text-warning">◐</span> waiting · dashed edge → the service it waits on
          </span>
          <span><span class="text-info">◌</span> spawning</span>
          <span><span class="text-warning font-mono">⁺¹</span> queued turns</span>
          <span><span class="text-success">⤸</span> reply arc</span>
          <span><span class="text-error">◉</span> failure flash</span>
          <span>☕ compacting</span>
        </div>

        <section id="pipeline-inflight" class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="text-xs uppercase tracking-wider opacity-60 mb-2">In flight · user requests</h2>
          <%= cond do %>
            <% @story == nil or @story[:feed_status] != :ok -> %>
              <p class="text-sm opacity-60">
                event feed unavailable — the canvas stays quiet; the node table below still reflects the snapshot.
              </p>
            <% @in_flight == [] -> %>
              <p class="text-sm opacity-60">nobody waiting</p>
            <% true -> %>
              <div class="space-y-1 font-mono text-sm">
                <div :for={ep <- @in_flight} class="flex items-baseline gap-3">
                  <span class="min-w-32 truncate">
                    @{ep.user}<span :if={ep.count > 1} class="opacity-50"> ·+{ep.count - 1}</span>
                  </span>
                  <span class="opacity-80">{short(ep.agent) || "routing…"}</span>
                  <span class={activity_tone(ep.activity)}>{ep.activity}</span>
                  <span :if={ep.stalled} class="badge badge-error badge-xs">stalled</span>
                  <span class="tnum ml-auto opacity-60">{sec(ep.elapsed_s)}s</span>
                </div>
              </div>
          <% end %>
          <p class="text-[0.7rem] opacity-40 mt-2">
            true state, updated instantly — the canvas above replays the same events at causal pace
          </p>
        </section>

        <details :if={@snapshot} class="text-sm">
          <summary class="cursor-pointer opacity-70">Nodes (table fallback)</summary>
          <table class="table table-sm mt-2">
            <thead>
              <tr>
                <th>user / name</th>
                <th>type</th>
                <th>state</th>
                <th>session</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={n <- @nodes}
                class={[n["type"] == "agent" && n["session_id"] && "row-press"]}
                phx-click={n["type"] == "agent" && n["session_id"] && "inspect"}
                phx-value-session_id={n["session_id"]}
              >
                <td>
                  <.identity
                    :if={n["type"] == "agent"}
                    user={n["user"]}
                    session_id={n["session_id"]}
                    size={:sm}
                  />
                  <span :if={n["type"] != "agent"} class="font-mono">{n["name"]}</span>
                </td>
                <td>{n["type"]}</td>
                <td>
                  <.live_dot :if={n["type"] == "agent"} state={n["state"]} />
                  <span
                    :if={n["type"] != "agent"}
                    class="opacity-50"
                  >
                    {n["subtype"]}
                  </span>
                </td>
                <td class="font-mono text-xs opacity-60">{n["session_id"]}</td>
              </tr>
            </tbody>
          </table>
        </details>

        <div :if={is_nil(@snapshot)} class="opacity-60">Waiting for the first snapshot…</div>
      </div>
    </Layouts.app>
    """
  end

  # Pool saturation for the header gauge: leased/size with a green→amber→red tone.
  defp pool_meta(snap) do
    case get_in(snap, ["summary", "pool"]) do
      %{"leased" => l, "size" => s} when is_integer(s) and s > 0 ->
        pct = round(l / s * 100)
        %{ok: true, leased: l, size: s, pct: pct, tone: pool_tone(pct)}

      %{"leased" => l, "size" => s} ->
        %{ok: true, leased: l, size: s, pct: 0, tone: pool_tone(0)}

      _ ->
        %{ok: false, leased: 0, size: 0, pct: 0, tone: pool_tone(0)}
    end
  end

  defp pool_tone(pct) when pct >= 90, do: "var(--color-error)"
  defp pool_tone(pct) when pct >= 70, do: "var(--color-warning)"
  defp pool_tone(_pct), do: "var(--color-success)"

  # Pool slots only (config :pipeline_layout agent_pattern) — sample/template
  # agents are swarm members but not part of the user-request pipeline.
  defp agent_names(snap) do
    re =
      case Application.get_env(:subzero_swarm_dashboard, :pipeline_layout, %{})[:agent_pattern] do
        nil -> nil
        pattern -> Regex.compile!(pattern)
      end

    for n <- snap["nodes"] || [],
        n["type"] == "agent",
        re == nil or Regex.match?(re, n["name"]),
        do: n["name"]
  end

  # ── in-flight strip (TRUE state from @story — not the paced animation) ────────
  defp short(nil), do: nil
  defp short(name), do: String.replace(name, "wingston_agent_", "agent_")

  defp activity_tone("waiting on " <> _), do: "text-warning"
  defp activity_tone("thinking"), do: "text-success"
  defp activity_tone("spawning"), do: "text-info"
  defp activity_tone(_activity), do: "opacity-60"

  # ── table fallback rows (with the joined user identity) ──────────────────────
  defp table_nodes(nil), do: []

  defp table_nodes(snap) do
    by_cid = Map.new(snap["sessions"] || [], &{&1["session_id"], &1})

    Enum.map(snap["nodes"] || [], fn n ->
      sess = n["session_id"] && by_cid[n["session_id"]]

      n
      |> Map.put("user", sess && sess["user"])
      |> Map.put("state", (sess && sess["state"]) || n["state"])
    end)
  end
end
