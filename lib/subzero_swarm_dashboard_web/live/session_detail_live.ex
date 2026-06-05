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

  # Live refresh: re-fetch transcript + activity on every snapshot tick (same pulse
  # as the rest of the page). :load re-assigns without a loading flash.
  def handle_info({:snapshot, _snap}, socket) do
    if connected?(socket), do: send(self(), :load)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :session, find_session(assigns[:snapshot], assigns.session_id))

    ~H"""
    <Layouts.app flash={@flash} active={:sessions} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript} inspect_activity={@inspect_activity}>
      <div class="space-y-5 max-w-3xl">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/sessions"} class="btn btn-ghost btn-xs gap-1">
            <.icon name="hero-arrow-left" class="size-3.5" /> Sessions
          </.link>
        </div>

        <div class="flex items-center justify-between gap-4 flex-wrap">
          <.identity user={@session && @session["user"]} session_id={@session_id} size={:lg} />
          <.live_dot :if={@session} state={@session["state"]} label />
        </div>

        <div :if={@session} class="flex flex-wrap gap-2 text-sm">
          <span class="badge badge-ghost font-mono text-xs">{@session_id}</span>
          <span class="badge badge-ghost">{@session["transport"]}</span>
          <span class="badge badge-ghost">agent {@session["agent"]}</span>
          <span
            :for={{k, v} <- @session["transport_ref"] || %{}}
            class="badge badge-outline font-mono text-xs"
          >
            {k}={v}
          </span>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-1">Conversation</h2>
          <p class="text-xs opacity-50 mb-2">
            The clean user ↔ Wingston back-and-forth, saved to the database — it
            <strong>survives agent restarts</strong>. (Empty if persistence is off.)
          </p>
          <.transcript transcript={@transcript} />
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-1">Agent activity <span class="text-xs font-normal opacity-50">· live</span></h2>
          <p class="text-xs opacity-50 mb-2">
            The agent's raw working log for this slot right now — messages in, tool
            calls, results, sends. <strong>Ephemeral</strong>: wiped when the slot is recycled.
          </p>
          <.activity_timeline activity={@activity} />
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

  defp find_session(nil, _id), do: nil
  defp find_session(snap, id), do: Enum.find(snap["sessions"] || [], &(&1["session_id"] == id))
end
