defmodule SubzeroSwarmDashboardWeb.LogsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboardWeb.DashHooks

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Logs", selected: nil, logs: nil)}

  @impl true
  def handle_event("select", %{"session_id" => ""}, socket),
    do: {:noreply, assign(socket, selected: nil, logs: nil)}

  def handle_event("select", %{"session_id" => submitted}, socket) do
    case resolve_session_id(socket, submitted) do
      nil ->
        {:noreply, assign(socket, selected: nil, logs: nil)}

      sid ->
        if socket.assigns[:reveal_transcripts] do
          send(self(), {:load_logs, sid})
          {:noreply, assign(socket, selected: sid, logs: :loading)}
        else
          {:noreply, assign(socket, selected: sid, logs: :hidden)}
        end
    end
  end

  @impl true
  def handle_info(:load, socket) do
    if socket.assigns[:reveal_transcripts] && socket.assigns[:selected] do
      send(self(), {:load_logs, socket.assigns.selected})
      {:noreply, assign(socket, logs: :loading)}
    else
      logs = if socket.assigns[:selected], do: :hidden, else: nil
      {:noreply, assign(socket, logs: logs)}
    end
  end

  def handle_info({:load_logs, sid}, socket) do
    if socket.assigns[:reveal_transcripts] && socket.assigns[:selected] == sid do
      {:noreply, assign(socket, logs: SwarmClient.session_logs(socket.assigns.swarm, sid))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true

    assigns =
      assign(assigns,
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?),
        session_options: session_options(assigns[:snapshot], assigns[:selected], privacy?)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:logs}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
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
          <form id="logs-session-select-form" phx-change="select">
            <select
              id="logs-session-select"
              name="session_id"
              class="select select-bordered select-sm font-mono"
            >
              <option value="">select a session…</option>
              <option
                :for={opt <- @session_options}
                value={opt.value}
                selected={opt.selected}
              >
                {opt.label}
              </option>
            </select>
          </form>
          <span class="ml-auto text-xs opacity-50">
            wiped on slot recycle · durable transcript on the
            <.link navigate={~p"/sessions"} class="link">session</.link>
            detail
          </span>
        </div>

        <.logs
          logs={@logs}
          selected={@selected}
          privacy={@privacy}
          revealed={@reveal_transcripts}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :logs, :any, required: true
  attr :selected, :any, default: nil
  attr :privacy, :boolean, default: false
  attr :revealed, :boolean, default: false

  defp logs(%{revealed: false, selected: selected} = assigns) when not is_nil(selected) do
    ~H"""
    <div id="logs-sensitive-gate">
      <.sensitive_reveal />
    </div>
    """
  end

  defp logs(%{privacy: true, logs: {:ok, %{"logs" => entries}}} = assigns)
       when is_list(entries) do
    assigns = assign(assigns, :line_count, length(entries))

    ~H"""
    <div id="logs-slot-output">
      <.panel title="Slot output">
        <:meta>
          <button
            id="logs-hide-sensitive"
            type="button"
            phx-click="transcripts_hide"
            class="btn btn-ghost btn-xs gap-1 opacity-60"
          >
            <.icon name="hero-eye-slash" class="size-3.5" /> hide sensitive evidence
          </button>
          <span class="font-mono">{line_count_label(@line_count)}</span>
        </:meta>
        <.empty_state
          icon="hero-eye-slash"
          msg="Raw slot output hidden in privacy mode."
          hint={"#{line_count_label(@line_count)} suppressed."}
        />
      </.panel>
    </div>
    """
  end

  defp logs(%{logs: {:ok, %{"logs" => [_ | _]}}} = assigns) do
    ~H"""
    <div id="logs-slot-output">
      <.panel title="Slot output">
        <:meta>
          <button
            id="logs-hide-sensitive"
            type="button"
            phx-click="transcripts_hide"
            class="btn btn-ghost btn-xs gap-1 opacity-60"
          >
            <.icon name="hero-eye-slash" class="size-3.5" /> hide sensitive evidence
          </button>
          <span class="font-mono">{@selected}</span>
        </:meta>
        <.activity_timeline activity={@logs} />
      </.panel>
    </div>
    """
  end

  defp logs(%{logs: :hidden} = assigns) do
    ~H"""
    <div id="logs-sensitive-gate">
      <.sensitive_reveal />
    </div>
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
    <div id="logs-loading" class="opacity-60 py-6 text-center text-sm">loading…</div>
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

  defp session_options(snapshot, selected, false) do
    for s <- sessions(snapshot) do
      sid = s["session_id"]
      %{value: sid, label: "#{sid} (#{s["agent"]})", selected: selected == sid}
    end
  end

  defp session_options(snapshot, selected, true) do
    snapshot
    |> sessions()
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      sid = s["session_id"]

      %{
        value: "session:#{i}",
        label: "session #{i + 1} (#{s["agent"]})",
        selected: selected == sid
      }
    end)
  end

  defp resolve_session_id(_socket, ""), do: nil

  defp resolve_session_id(socket, "session:" <> index) do
    with {i, ""} <- Integer.parse(index),
         %{"session_id" => sid} <- Enum.at(sessions(socket.assigns[:snapshot]), i) do
      sid
    else
      _ -> nil
    end
  end

  defp resolve_session_id(_socket, sid), do: sid

  defp line_count_label(1), do: "1 line"
  defp line_count_label(n), do: "#{n} lines"
end
