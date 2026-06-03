defmodule SubzeroSwarmDashboardWeb.LogsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Logs")}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:logs} swarm={@swarm}>
      <div class="space-y-4 max-w-3xl">
        <h1 class="text-xl font-semibold">Logs <span class="text-xs opacity-50">raw execution output</span></h1>
        <div class="card bg-base-200 p-6">
          <p class="text-sm">
            Raw per-slot output is <b>ephemeral</b> (it's wiped when a slot is recycled), so logs
            are best viewed per session. Open a session and its transcript shows the durable record.
          </p>
          <p class="text-sm opacity-60 mt-2">
            A dedicated raw-logs feed needs the swarm's <code>/sessions/:id/logs</code> route
            (spec §6.2c, v2). Structured lifecycle events live under
            <.link navigate={~p"/events"} class="link">Events</.link>.
          </p>
          <.link navigate={~p"/sessions"} class="btn btn-sm btn-primary mt-3 w-fit">Go to Sessions</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
