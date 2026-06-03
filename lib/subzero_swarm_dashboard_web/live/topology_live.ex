defmodule SubzeroSwarmDashboardWeb.TopologyLive do
  use SubzeroSwarmDashboardWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Topology", show_idle: false)}

  @impl true
  def handle_event("toggle_idle", _p, socket),
    do: {:noreply, assign(socket, show_idle: !socket.assigns.show_idle)}

  @impl true
  def handle_info({:snapshot, snap}, socket),
    do: {:noreply, push_event(socket, "topology:graph", graph_map(snap))}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:topology} swarm={@swarm}>
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-xl font-semibold">Topology</h1>
          <div :if={@snapshot} class="text-sm flex items-center gap-3">
            <span class="badge badge-ghost">pool {pool_str(@snapshot)}</span>
            <label class="cursor-pointer flex items-center gap-1">
              <input type="checkbox" class="checkbox checkbox-xs" phx-click="toggle_idle" checked={@show_idle} />
              show idle slots
            </label>
          </div>
        </div>

        <div
          :if={@snapshot}
          id="topology"
          phx-hook="Topology"
          phx-update="ignore"
          class="w-full h-[60vh] rounded border border-base-300 bg-base-100"
        >
        </div>

        <div class="flex gap-4 text-xs opacity-70">
          <span><span class="inline-block w-3 h-3 align-middle bg-info rounded-sm"></span> object (deterministic)</span>
          <span><span class="inline-block w-3 h-3 align-middle bg-success rounded-full"></span> agent (LLM · per-session)</span>
        </div>

        <details :if={@snapshot} class="text-sm">
          <summary class="cursor-pointer opacity-70">Nodes (table fallback)</summary>
          <table class="table table-sm mt-2">
            <thead>
              <tr><th>name</th><th>type</th><th>subtype/state</th><th>session</th></tr>
            </thead>
            <tbody>
              <tr :for={n <- @snapshot["nodes"]}>
                <td class="font-mono">{n["name"]}</td>
                <td>{n["type"]}</td>
                <td>{n["subtype"] || n["state"]}</td>
                <td class="font-mono text-xs">{n["session_id"]}</td>
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

  defp graph_map(nil), do: %{nodes: [], edges: []}

  defp graph_map(snap) do
    nodes =
      Enum.map(snap["nodes"] || [], fn n ->
        %{
          data: %{
            id: n["name"],
            label: n["name"],
            type: n["type"],
            subtype: n["subtype"],
            state: n["state"],
            session: n["session_id"]
          }
        }
      end)

    edges =
      Enum.map(snap["edges"] || [], fn e ->
        %{data: %{id: "#{e["from"]}__#{e["to"]}", source: e["from"], target: e["to"]}}
      end)

    %{nodes: nodes, edges: edges}
  end
end
