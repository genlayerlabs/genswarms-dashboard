defmodule SubzeroSwarmDashboardWeb.LogsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Logs", selected: nil, logs: nil)}

  @impl true
  def handle_event("select", %{"session_id" => ""}, socket),
    do: {:noreply, assign(socket, selected: nil, logs: nil)}

  def handle_event("select", %{"session_id" => sid}, socket) do
    send(self(), {:load_logs, sid})
    {:noreply, assign(socket, selected: sid, logs: :loading)}
  end

  @impl true
  def handle_info({:load_logs, sid}, socket),
    do: {:noreply, assign(socket, logs: SwarmClient.session_logs(socket.assigns.swarm, sid))}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:logs}
      swarm={@swarm}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5 max-w-3xl">
        <h1 class="text-2xl">
          Logs
          <span class="text-xs opacity-50 font-sans align-middle">
            raw per-session output (ephemeral)
          </span>
        </h1>

        <div class="flex flex-wrap gap-2 items-center rounded-box border border-base-300 bg-base-200/60 px-3 py-2.5 text-sm">
          <form phx-change="select">
            <select name="session_id" class="select select-bordered select-sm font-mono">
              <option value="">select a session…</option>
              <option
                :for={s <- sessions(@snapshot)}
                value={s["session_id"]}
                selected={@selected == s["session_id"]}
              >
                {s["session_id"]} ({s["agent"]})
              </option>
            </select>
          </form>
          <span class="ml-auto text-xs opacity-50">
            wiped on slot recycle · durable transcript on the
            <.link navigate={~p"/sessions"} class="link">session</.link>
            detail
          </span>
        </div>

        <.logs logs={@logs} selected={@selected} />
      </div>
    </Layouts.app>
    """
  end

  attr :logs, :any, required: true
  attr :selected, :any, default: nil

  defp logs(%{logs: {:ok, %{"logs" => [_ | _]}}} = assigns) do
    ~H"""
    <.panel title="Slot output">
      <:meta>
        <span class="font-mono">{@selected}</span>
      </:meta>
      <.activity_timeline activity={@logs} />
    </.panel>
    """
  end

  defp logs(%{logs: {:ok, _}} = assigns) do
    ~H"""
    <.empty_state
      icon="hero-document-text"
      msg="No raw output (slot recycled or never ran)."
      hint="Raw slot output is ephemeral — the durable conversation lives on the session detail."
    />
    """
  end

  defp logs(%{logs: :loading} = assigns) do
    ~H"""
    <div class="opacity-60 py-6 text-center text-sm">loading…</div>
    """
  end

  defp logs(%{selected: nil} = assigns) do
    ~H"""
    <.empty_state
      icon="hero-document-text"
      msg="Pick a session to see its raw slot output."
      hint="Raw slot output is wiped when a slot is recycled — the durable conversation is on the session detail."
    />
    """
  end

  defp logs(assigns) do
    ~H"""
    <.empty_state icon="hero-document-text" msg="Logs unavailable." />
    """
  end

  defp sessions(nil), do: []
  defp sessions(snap), do: snap["sessions"] || []
end
