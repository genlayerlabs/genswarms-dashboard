defmodule SubzeroSwarmDashboardWeb.TopologyLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboardWeb.DashHooks

  @impl true
  def mount(_params, _session, socket) do
    layout = Application.get_env(:subzero_swarm_dashboard, :pipeline_layout, %{})

    {:ok,
     socket
     |> assign(page_title: "Topology", debug: false, agent_re: compile_agent_pattern(layout))
     |> push_event("pipeline:init", layout)}
  end

  # the pool-slot pattern is config — compile it once at mount, not on every
  # 3s snapshot tick
  defp compile_agent_pattern(layout) do
    case layout[:agent_pattern] do
      nil -> nil
      pattern -> Regex.compile!(pattern)
    end
  end

  # ?debug=1 shows the hook's trace rig. The hook el is phx-update="ignore", so
  # data-debug is read once AT MOUNT — the param arrives with the page load.
  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, debug: params["debug"] == "1")}

  @impl true
  # Raw display events drive the canvas; the hook owns playback timing (causal).
  def handle_info({:display_event, ev}, socket),
    do:
      {:noreply,
       push_event(
         socket,
         "pipeline:event",
         display_event_for_privacy(ev, socket.assigns[:privacy] == true)
       )}

  # Agent nodes are dynamic. Precedence (spec §5.5): the snapshot wins existence
  # (which slots are in the pool), the event story wins activity state.
  # `handles` carries a per-slot overlay for a leased slot: the session id it
  # serves (the canvas labels the node "agent_15" + that session id) and an
  # avatar seed (the telegram handle) — the identity lives in the drawn avatar,
  # not in a "@handle" text label.
  def handle_info({:snapshot, snap}, socket) do
    privacy? = socket.assigns[:privacy] == true
    inspect_lookup = DashHooks.inspect_lookup(snap)

    payload =
      %{
        agents: agent_names(snap, socket.assigns.agent_re),
        handles: agent_handles(snap, privacy?),
        sessions: agent_session_targets(snap, privacy?, inspect_lookup)
      }
      |> maybe_add_session_labels(snap, privacy?)

    socket =
      socket
      |> assign(:inspect_lookup, inspect_lookup)
      |> push_event("pipeline:agents", payload)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])

    assigns =
      assigns
      |> assign(:inspect_lookup, inspect_lookup)
      |> assign(:nodes, table_nodes(assigns[:snapshot], privacy?, inspect_lookup))
      |> assign(:gauge, pool_meta(assigns[:snapshot]))
      |> assign(:in_flight, (assigns[:story] && assigns.story[:in_flight]) || [])

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:topology}
      swarm={@swarm}
      snapshot={@snapshot}
      story={@story}
      privacy={@privacy}
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
              aria-label="pool saturation"
              aria-valuenow={@gauge.pct}
              aria-valuemin="0"
              aria-valuemax="100"
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
          class="pipeline-terminal w-full h-[64vh] rounded-box border relative overflow-hidden"
        >
        </div>

        <div
          id="pipeline-legend"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs opacity-70"
        >
          <span><span class="text-primary">●</span> thinking</span>
          <span>
            <span class="text-warning">◐</span> waiting · dashed edge → the service it waits on
          </span>
          <span><span class="text-info">◌</span> spawning</span>
          <span><span class="text-warning font-mono">⁺¹</span> queued turns</span>
          <span><span class="text-success">⤸</span> reply arc</span>
          <span><span class="text-error">◉</span> failure flash</span>
          <span>☕ compacting · 🤫 suppressed · ⛔ budget wall · ✓ cron ok</span>
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
                    @{display_handle(@snapshot, ep, @privacy)}
                  </span>
                  <span class="opacity-80">{short(ep.agent) || "routing…"}</span>
                  <span class={activity_tone(ep.activity)}>
                    {ep.activity}<span
                      :if={queued_turns(@story, ep) > 0}
                      class="opacity-60"
                      title="messages from this user waiting for the current turn to finish"
                    > · +{queued_turns(@story, ep)} queued</span>
                  </span>
                  <span :if={ep.stalled} class="badge badge-error badge-xs">stalled</span>
                  <span class="tnum ml-auto opacity-60">{duration(ep.elapsed_s)}</span>
                  <% inspect_target = inspect_value(@inspect_lookup, @privacy, ep.cid) %>
                  <%= if @privacy do %>
                    <button
                      :if={inspect_target}
                      type="button"
                      phx-click="inspect"
                      phx-value-session_id={inspect_target}
                      class="link link-hover text-xs opacity-70 whitespace-nowrap"
                    >
                      session
                    </button>
                  <% else %>
                    <.link
                      navigate={session_href(ep.cid)}
                      class="link link-hover text-xs opacity-70 whitespace-nowrap"
                    >
                      session
                    </.link>
                  <% end %>
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
                class={[n["type"] == "agent" && n["inspect_value"] && "row-press"]}
                phx-click={n["type"] == "agent" && n["inspect_value"] && "inspect"}
                phx-keydown={n["type"] == "agent" && n["inspect_value"] && "inspect"}
                phx-key="Enter"
                phx-value-session_id={n["inspect_value"]}
                tabindex={if(n["type"] == "agent" && n["inspect_value"], do: "0")}
              >
                <td>
                  <%= if n["type"] == "agent" and @privacy do %>
                    <div class="flex items-center gap-2.5 min-w-0">
                      <.identity_avatar
                        user={n["raw_user"]}
                        session_id={n["raw_session_id"]}
                        size={:sm}
                      />
                      <span class="font-mono text-sm">•••</span>
                    </div>
                  <% else %>
                    <.identity
                      :if={n["type"] == "agent"}
                      user={n["user"]}
                      session_id={n["session_id"]}
                      size={:sm}
                    />
                  <% end %>
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
  defp agent_names(snap, re) do
    for n <- snap["nodes"] || [],
        n["type"] == "agent",
        re == nil or Regex.match?(re, n["name"]),
        do: n["name"]
  end

  @doc """
  agent slot => avatar seed for the canvas. The seed is the telegram handle,
  falling back to adapter label / name / session id, so every leased slot gets a
  stable generated avatar even without a handle — the identity lives in the drawn
  avatar, not a "@handle" text label. Active sessions win over idle leftovers, so
  a recycled slot never wears the previous conversation's avatar. The session id
  the slot serves (drawn under the slot id) comes from `agent_sessions/1`. Public
  for unit tests.
  """
  def agent_handles(snap, privacy? \\ false) do
    (snap["sessions"] || [])
    |> Enum.filter(&is_binary(&1["agent"]))
    # actives sort LAST so they win the Map.new overwrite
    |> Enum.sort_by(&(&1["state"] == "active"))
    |> Enum.reduce(%{}, fn s, acc ->
      case avatar_seed(s) do
        nil -> acc
        seed -> Map.put(acc, s["agent"], avatar_seed_for_display(seed, privacy?))
      end
    end)
  end

  @doc """
  agent slot => session id, for canvas click→inspect and the label sub-line.
  Same active-wins precedence as `agent_handles/1` but NO display filter: a
  session without handle/label/name must still be clickable and labelled.
  Public for unit tests.
  """
  def agent_sessions(snap) do
    (snap["sessions"] || [])
    |> Enum.filter(&(is_binary(&1["agent"]) and is_binary(&1["session_id"])))
    # actives sort LAST so they win the Map.new overwrite
    |> Enum.sort_by(&(&1["state"] == "active"))
    |> Map.new(&{&1["agent"], &1["session_id"]})
  end

  defp agent_session_targets(snap, privacy?, inspect_lookup) do
    snap
    |> agent_sessions()
    |> Map.new(fn {agent, sid} -> {agent, inspect_value(inspect_lookup, privacy?, sid)} end)
  end

  defp agent_session_labels(snap, privacy?) do
    snap
    |> agent_sessions()
    |> Map.new(fn {agent, sid} -> {agent, display_session_id(sid, privacy?)} end)
  end

  defp maybe_add_session_labels(payload, _snap, false), do: payload

  defp maybe_add_session_labels(payload, snap, true),
    do: Map.put(payload, :session_labels, agent_session_labels(snap, true))

  # telegram handle first, then adapter label / name, and the session id as a
  # last resort so a handle-less leased slot still gets a distinct avatar
  defp avatar_seed(s) do
    presence(get_in(s, ["user", "handle"])) ||
      presence(s["label"]) ||
      presence(get_in(s, ["user", "name"])) ||
      presence(s["session_id"])
  end

  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(_), do: nil

  defp avatar_seed_for_display(seed, false), do: seed

  defp avatar_seed_for_display(seed, true),
    do: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)

  defp display_event_for_privacy(ev, false), do: ev

  defp display_event_for_privacy(%{} = ev, true) do
    Map.new(ev, fn {key, value} ->
      {key, redact_display_event_value(to_string(key), value)}
    end)
  end

  defp display_event_for_privacy(ev, _privacy?), do: ev

  defp redact_display_event_value("cid", value) when is_binary(value),
    do: "cid:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp redact_display_event_value(key, value)
       when key in ["session_id", "chat_id", "conversation_id"] and is_binary(value),
       do: display_session_id(value, true)

  defp redact_display_event_value(key, value)
       when key in ["handle", "username", "name", "label", "user"] and is_binary(value),
       do: "•••"

  defp redact_display_event_value(key, value)
       when key in ["text", "message", "content"] and is_binary(value),
       do: PrivacyRedactor.mask_text(value)

  defp redact_display_event_value(_key, value), do: value

  # ── in-flight strip (TRUE state from @story — not the paced animation) ────────
  defp display_handle(_snap, _ep, true), do: "•••"
  defp display_handle(snap, ep, _privacy?), do: handle_for(snap, ep.cid, ep.user)

  defp inspect_value(lookup, privacy?, sid),
    do: DashHooks.inspect_value(lookup, privacy? == true, sid)

  defp short(nil), do: nil
  defp short(name), do: String.replace(name, "wingston_agent_", "agent_")

  # thinking = primary everywhere (Overview strip, the legend dot above) —
  # green is reserved for success/replied
  defp activity_tone("waiting on " <> _), do: "text-warning"
  defp activity_tone("thinking"), do: "text-primary"
  defp activity_tone("spawning"), do: "text-info"
  defp activity_tone(_activity), do: "opacity-60"

  # ── table fallback rows (with the joined user identity) ──────────────────────
  defp table_nodes(nil, _privacy?, _inspect_lookup), do: []

  defp table_nodes(snap, privacy?, inspect_lookup) do
    by_cid = Map.new(snap["sessions"] || [], &{&1["session_id"], &1})

    Enum.map(snap["nodes"] || [], fn n ->
      sess = n["session_id"] && by_cid[n["session_id"]]
      raw_sid = n["session_id"]

      n
      |> Map.put("user", sess && sess["user"])
      |> Map.put("state", (sess && sess["state"]) || n["state"])
      |> Map.put("raw_user", sess && sess["user"])
      |> Map.put("raw_session_id", raw_sid)
      |> Map.put("inspect_value", inspect_value(inspect_lookup, privacy?, raw_sid))
      |> maybe_mask_table_node(privacy?)
    end)
  end

  defp maybe_mask_table_node(n, false), do: n

  defp maybe_mask_table_node(n, true) do
    n
    |> Map.put("user", nil)
    |> Map.put("session_id", display_session_id(n["session_id"], true))
  end

  defp display_session_id(nil, _privacy?), do: nil
  defp display_session_id(sid, false), do: sid

  defp display_session_id(sid, true) when is_binary(sid) do
    case PrivacyRedactor.mask_cid(sid) do
      ^sid -> "•••"
      masked -> masked
    end
  end
end
