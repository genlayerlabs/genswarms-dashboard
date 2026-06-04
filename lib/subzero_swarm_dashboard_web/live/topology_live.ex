defmodule SubzeroSwarmDashboardWeb.TopologyLive do
  use SubzeroSwarmDashboardWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Topology", show_idle: false, q: "")}

  @impl true
  def handle_event("toggle_idle", _p, socket) do
    socket = assign(socket, show_idle: !socket.assigns.show_idle)
    {:noreply, push_graph(socket)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q) |> push_event("topology:focus", %{q: q})}
  end

  @live_events ~w(agent_status message_routed message_broadcast agent_added agent_removed topology_changed)

  @impl true
  def handle_info({:snapshot, snap}, socket),
    do: {:noreply, push_event(socket, "topology:graph", graph_map(snap, socket.assigns.show_idle))}

  # Live WS events → instant incremental graph updates (no wait for the 3s poll).
  def handle_info({:event, type, payload}, socket) when type in @live_events,
    do: {:noreply, push_event(socket, "topology:event", %{type: type, payload: payload})}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp push_graph(socket),
    do: push_event(socket, "topology:graph", graph_map(socket.assigns[:snapshot], socket.assigns.show_idle))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :nodes, table_nodes(assigns[:snapshot], assigns.show_idle))

    ~H"""
    <Layouts.app flash={@flash} active={:topology} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript}>
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h1 class="text-2xl">Topology</h1>
          <div :if={@snapshot} class="flex items-center gap-3 flex-wrap">
            <form phx-change="search">
              <label class="input input-bordered input-sm flex items-center gap-2">
                <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
                <input type="text" name="q" value={@q} placeholder="focus @handle / object" class="grow bg-transparent outline-none w-44" autocomplete="off" />
              </label>
            </form>
            <span class="badge badge-ghost tnum">pool {pool_str(@snapshot)}</span>
            <label class="cursor-pointer flex items-center gap-1.5 text-sm">
              <input type="checkbox" class="toggle toggle-xs toggle-success" phx-click="toggle_idle" checked={@show_idle} />
              idle slots
            </label>
          </div>
        </div>

        <div
          :if={@snapshot}
          id="topology"
          phx-hook="Topology"
          phx-update="ignore"
          class="w-full h-[64vh] rounded-box border border-base-300 bg-base-100 relative overflow-hidden"
        >
        </div>

        <div class="flex flex-wrap gap-4 text-xs opacity-70">
          <span class="flex items-center gap-1.5"><span class="inline-block w-3 h-3 align-middle bg-info rounded-sm"></span> object (deterministic)</span>
          <span class="flex items-center gap-1.5"><span class="signal-dot"></span> agent · live</span>
          <span class="flex items-center gap-1.5"><span class="inline-block w-2.5 h-2.5 rounded-full bg-base-content/30"></span> agent · idle</span>
          <span class="opacity-60">click an agent to inspect · click any node to isolate · click empty space to reset</span>
        </div>

        <details :if={@snapshot} class="text-sm">
          <summary class="cursor-pointer opacity-70">Nodes (table fallback)</summary>
          <table class="table table-sm mt-2">
            <thead>
              <tr><th>user / name</th><th>type</th><th>state</th><th>session</th></tr>
            </thead>
            <tbody>
              <tr
                :for={n <- @nodes}
                class={[n["type"] == "agent" && n["session_id"] && "row-press"]}
                phx-click={n["type"] == "agent" && n["session_id"] && "inspect"}
                phx-value-session_id={n["session_id"]}
              >
                <td>
                  <.identity :if={n["type"] == "agent"} user={n["user"]} session_id={n["session_id"]} size={:sm} />
                  <span :if={n["type"] != "agent"} class="font-mono">{n["name"]}</span>
                </td>
                <td>{n["type"]}</td>
                <td><.live_dot :if={n["type"] == "agent"} state={n["state"]} /><span :if={n["type"] != "agent"} class="opacity-50">{n["subtype"]}</span></td>
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

  defp pool_str(snap) do
    case get_in(snap, ["summary", "pool"]) do
      %{"leased" => l, "size" => s} -> "#{l} / #{s}"
      _ -> "—"
    end
  end

  # ── graph payload for the cytoscape hook ─────────────────────────────────────
  defp graph_map(nil, _show_idle), do: %{nodes: [], edges: []}

  defp graph_map(snap, show_idle) do
    by_cid = Map.new(snap["sessions"] || [], &{&1["session_id"], &1})

    nodes =
      (snap["nodes"] || [])
      |> Enum.map(&node_data(&1, by_cid))
      |> Enum.reject(&drop_idle?(&1, show_idle))

    kept = MapSet.new(nodes, & &1.data.id)

    edges =
      for e <- snap["edges"] || [],
          MapSet.member?(kept, e["from"]) and MapSet.member?(kept, e["to"]) do
        %{data: %{id: "#{e["from"]}__#{e["to"]}", source: e["from"], target: e["to"]}}
      end

    %{nodes: nodes, edges: edges}
  end

  defp node_data(n, by_cid) do
    sess = n["session_id"] && by_cid[n["session_id"]]

    {label, state} =
      if n["type"] == "agent" do
        {agent_label(sess, n), to_string((sess && sess["state"]) || n["state"] || "")}
      else
        {n["name"], to_string(n["state"] || "")}
      end

    %{
      data: %{
        id: n["name"],
        label: label,
        type: n["type"],
        subtype: n["subtype"],
        state: state,
        session: n["session_id"]
      }
    }
  end

  defp agent_label(sess, n) do
    handle = sess && get_in(sess, ["user", "handle"])
    name = sess && get_in(sess, ["user", "name"])

    cond do
      present(handle) -> "@#{handle}"
      present(name) -> name
      true -> n["name"]
    end
  end

  # idle agents are hidden unless "idle slots" is on; objects always stay.
  defp drop_idle?(%{data: %{type: "agent", state: state}}, show_idle),
    do: not show_idle and state != "active"

  defp drop_idle?(_node, _show_idle), do: false

  # ── table fallback rows (with the joined user identity) ──────────────────────
  defp table_nodes(nil, _show_idle), do: []

  defp table_nodes(snap, show_idle) do
    by_cid = Map.new(snap["sessions"] || [], &{&1["session_id"], &1})

    (snap["nodes"] || [])
    |> Enum.map(fn n ->
      sess = n["session_id"] && by_cid[n["session_id"]]

      n
      |> Map.put("user", sess && sess["user"])
      |> Map.put("state", (sess && sess["state"]) || n["state"])
    end)
    |> Enum.reject(fn n -> not show_idle and n["type"] == "agent" and n["state"] != "active" end)
  end

  defp present(v) when is_binary(v), do: String.trim(v) != ""
  defp present(_), do: false
end
