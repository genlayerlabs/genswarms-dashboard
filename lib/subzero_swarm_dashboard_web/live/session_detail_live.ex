defmodule SubzeroSwarmDashboardWeb.SessionDetailLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: send(self(), :load)

    {:ok,
     assign(socket,
       page_title: "Session #{id}",
       session_id: id,
       transcript: :loading,
       activity: :loading
     )}
  end

  @impl true
  def handle_info(:load, socket) do
    swarm = socket.assigns.swarm
    id = socket.assigns.session_id

    {:noreply,
     assign(socket,
       transcript: SwarmClient.session_history(swarm, id),
       activity: SwarmClient.session_logs(swarm, id)
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :session, find_session(assigns[:snapshot], assigns.session_id))

    ~H"""
    <Layouts.app flash={@flash} active={:sessions} swarm={@swarm}>
      <div class="space-y-4 max-w-3xl">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/sessions"} class="link text-sm">&larr; Sessions</.link>
        </div>
        <h1 class="text-xl font-semibold font-mono">{@session_id}</h1>

        <div :if={@session} class="flex flex-wrap gap-2 text-sm">
          <span class="badge badge-ghost">{@session["transport"]}</span>
          <span class="badge badge-ghost">agent {@session["agent"]}</span>
          <span class={["badge", @session["state"] == "active" && "badge-success"]}>
            {@session["state"]}
          </span>
          <span
            :for={{k, v} <- @session["transport_ref"] || %{}}
            class="badge badge-outline font-mono"
          >
            {k}={v}
          </span>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Transcript</h2>
          <p class="text-xs opacity-50 mb-2">Durable conversation (survives slot recycling).</p>
          <.transcript transcript={@transcript} />
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Activity</h2>
          <p class="text-xs opacity-50 mb-2">
            Raw slot output for the bound agent — ephemeral, wiped on recycle.
          </p>
          <.activity activity={@activity} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :transcript, :any, required: true

  defp transcript(%{transcript: {:ok, %{"turns" => turns, "source" => source}}} = assigns)
       when turns != [] do
    assigns = assign(assigns, turns: turns, source: source)

    ~H"""
    <div class="text-xs opacity-60 mb-2">source: {@source}</div>
    <div class="space-y-2">
      <div :for={t <- @turns} class={["chat", (t["role"] == "user" && "chat-start") || "chat-end"]}>
        <div class="chat-header text-xs opacity-60">{t["role"]}</div>
        <div class="chat-bubble whitespace-pre-wrap">{t["content"]}</div>
      </div>
    </div>
    """
  end

  defp transcript(%{transcript: {:ok, %{"source" => source}}} = assigns) do
    assigns = assign(assigns, :source, source)

    ~H"""
    <div class="text-sm opacity-60">No transcript ({@source}).</div>
    """
  end

  defp transcript(%{transcript: :loading} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">loading…</div>
    """
  end

  defp transcript(assigns) do
    ~H"""
    <div class="text-sm opacity-60">Transcript unavailable.</div>
    """
  end

  attr :activity, :any, required: true

  defp activity(%{activity: {:ok, %{"logs" => [_ | _] = entries} = body}} = assigns) do
    assigns = assign(assigns, entries: entries, source: body["source"])

    ~H"""
    <div class="text-xs opacity-60 mb-2">source: {@source}</div>
    <ol class="relative border-l border-base-300 ml-2 space-y-3">
      <li :for={e <- @entries} class="ml-4">
        <span class="absolute -left-1.5 w-3 h-3 rounded-full bg-base-content/30"></span>
        <div class="flex items-baseline gap-2 text-xs opacity-60">
          <time class="font-mono">{e["timestamp"]}</time>
          <span class="badge badge-ghost badge-xs">{e["role"]}</span>
        </div>
        <div class="text-sm whitespace-pre-wrap">{e["content"]}</div>
      </li>
    </ol>
    """
  end

  defp activity(%{activity: {:ok, _}} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">No raw output (slot recycled or never ran).</div>
    """
  end

  defp activity(%{activity: :loading} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">loading…</div>
    """
  end

  defp activity(assigns) do
    ~H"""
    <div class="text-sm opacity-60">Activity unavailable.</div>
    """
  end

  defp find_session(nil, _id), do: nil
  defp find_session(snap, id), do: Enum.find(snap["sessions"] || [], &(&1["session_id"] == id))
end
