defmodule SubzeroSwarmDashboardWeb.EventsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Events", events: :loading, level: "", timer: nil)
    if connected?(socket), do: send(self(), :load)
    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"level" => level}, socket) do
    # Reload now; reload/1 cancels the pending timer so we never start a second
    # self-perpetuating refresh chain.
    {:noreply, socket |> assign(level: level, events: :loading) |> reload()}
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Single recurring refresh: cancel any pending timer, fetch, reschedule one.
  defp reload(socket) do
    if ref = socket.assigns[:timer], do: Process.cancel_timer(ref)
    opts = if socket.assigns.level != "", do: %{level: socket.assigns.level, limit: 100}, else: %{limit: 100}
    timer = Process.send_after(self(), :load, @refresh_ms)
    assign(socket, events: SwarmClient.events(socket.assigns.swarm, opts), timer: timer)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:events} swarm={@swarm}>
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4">
          <h1 class="text-xl font-semibold">Events <span class="text-xs opacity-50">structured lifecycle facts</span></h1>
          <form phx-change="filter">
            <select name="level" class="select select-bordered select-sm">
              <option value="" selected={@level == ""}>all levels</option>
              <option value="error" selected={@level == "error"}>error</option>
              <option value="warning" selected={@level == "warning"}>warning</option>
              <option value="info" selected={@level == "info"}>info</option>
            </select>
          </form>
        </div>

        <.event_table events={@events} />
      </div>
    </Layouts.app>
    """
  end

  attr :events, :any, required: true

  defp event_table(%{events: {:ok, events}} = assigns) do
    assigns = assign(assigns, :events, events)

    ~H"""
    <table class="table table-xs">
      <thead>
        <tr><th>time</th><th>level</th><th>category</th><th>agent</th><th>message</th></tr>
      </thead>
      <tbody>
        <tr :for={e <- @events}>
          <td class="text-xs opacity-60 whitespace-nowrap">{e["timestamp"]}</td>
          <td><span class={["badge badge-xs", level_class(e["level"])]}>{e["level"]}</span></td>
          <td class="text-xs">{e["category"]}</td>
          <td class="font-mono text-xs">{e["agent"]}</td>
          <td class="text-xs">{e["message"]}</td>
        </tr>
        <tr :if={@events == []}><td colspan="5" class="opacity-60">No events.</td></tr>
      </tbody>
    </table>
    """
  end

  defp event_table(%{events: :loading} = assigns) do
    ~H"""
    <div class="opacity-60">loading…</div>
    """
  end

  defp event_table(assigns) do
    ~H"""
    <div class="opacity-60">Events unavailable (is the swarm API reachable?).</div>
    """
  end

  defp level_class("error"), do: "badge-error"
  defp level_class("warning"), do: "badge-warning"
  defp level_class(_), do: "badge-ghost"
end
