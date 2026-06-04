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
    <Layouts.app flash={@flash} active={:logs} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript}>
      <div class="space-y-5 max-w-3xl">
        <div class="flex items-center justify-between gap-4">
          <h1 class="text-2xl">
            Logs <span class="text-xs opacity-50 font-sans align-middle">raw per-session output (ephemeral)</span>
          </h1>
          <form phx-change="select">
            <select name="session_id" class="select select-bordered select-sm">
              <option value="">select a session…</option>
              <option :for={s <- sessions(@snapshot)} value={s["session_id"]} selected={@selected == s["session_id"]}>
                {s["session_id"]} ({s["agent"]})
              </option>
            </select>
          </form>
        </div>

        <.logs logs={@logs} selected={@selected} />

        <p class="text-xs opacity-50">
          Raw slot output is wiped when a slot is recycled. The durable conversation is on the
          <.link navigate={~p"/sessions"} class="link">session</.link> detail.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :logs, :any, required: true
  attr :selected, :any, default: nil

  defp logs(%{logs: {:ok, %{"logs" => [_ | _] = entries, "source" => source}}} = assigns) do
    text =
      Enum.map_join(entries, "\n", fn e ->
        "[#{e["timestamp"]}] #{e["role"]}: #{e["content"]}"
      end)

    assigns = assign(assigns, text: text, source: source)

    ~H"""
    <div class="text-xs opacity-60">source: {@source}</div>
    <pre class="bg-base-300 p-3 rounded text-xs overflow-x-auto whitespace-pre-wrap">{@text}</pre>
    """
  end

  defp logs(%{logs: {:ok, _}} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">No raw output (slot recycled or never ran).</div>
    """
  end

  defp logs(%{logs: :loading} = assigns) do
    ~H"""
    <div class="opacity-60">loading…</div>
    """
  end

  defp logs(%{selected: nil} = assigns) do
    ~H"""
    <div class="opacity-60">Pick a session to see its raw slot output.</div>
    """
  end

  defp logs(assigns) do
    ~H"""
    <div class="opacity-60">Logs unavailable.</div>
    """
  end

  defp sessions(nil), do: []
  defp sessions(snap), do: snap["sessions"] || []
end
