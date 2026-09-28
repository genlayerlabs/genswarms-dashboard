defmodule SubzeroSwarmDashboardWeb.LogsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboardWeb.DashHooks

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Logs", selected: nil, logs: nil, session_query: "")}

  @impl true
  def handle_event("select", %{"session_id" => ""}, socket),
    do: {:noreply, socket |> assign(selected: nil, logs: nil) |> DashHooks.refresh_snapshot()}

  def handle_event("select", %{"session_id" => submitted}, socket) do
    case resolve_session_id(socket, submitted) do
      nil ->
        {:noreply, socket}

      sid ->
        send(self(), {:load_logs, sid})

        {:noreply,
         socket |> assign(selected: sid, logs: :loading) |> DashHooks.refresh_snapshot()}
    end
  end

  def handle_event("session_search", %{"q" => q}, socket) when is_binary(q),
    do:
      {:noreply,
       socket |> assign(session_query: String.slice(q, 0, 256)) |> DashHooks.refresh_snapshot()}

  def handle_event("session_search", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:load_logs, sid}, socket),
    do: {:noreply, assign(socket, logs: SwarmClient.session_logs(socket.assigns.swarm, sid))}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true

    assigns =
      assign(assigns,
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?),
        session_options: session_options(assigns[:snapshot], assigns[:selected], privacy?),
        session_search: get_in(assigns[:snapshot] || %{}, ["_session_search"]),
        search_form: to_form(%{"q" => if(privacy?, do: "", else: assigns.session_query)})
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
          <.form for={@search_form} id="session-search-form" phx-change="session_search">
            <.input
              field={@search_form[:q]}
              type="search"
              label="Find session"
              placeholder="ID, name or handle"
              phx-debounce="300"
            />
          </.form>
          <span :if={@session_search} id="session-search-status" class="text-xs opacity-60">
            <%= if (@snapshot || %{})["sessions_available"] == false do %>
              Session source unavailable · {num(@session_search.total)} known matches ({num(
                @session_search.loaded
              )} loaded, up to {@session_search.limit}); total unknown
            <% else %>
              {num(@session_search.loaded)} loaded of {num(@session_search.total)} matches · up to {@session_search.limit}; selection kept
            <% end %>
          </span>
          <form id="logs-session-form" phx-change="select">
            <select
              id="logs-session-select"
              name="session_id"
              aria-label="Session"
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

        <.logs logs={@logs} selected={@selected} privacy={@privacy} />
      </div>
    </Layouts.app>
    """
  end

  attr :logs, :any, required: true
  attr :selected, :any, default: nil
  attr :privacy, :boolean, default: false

  defp logs(%{privacy: true, logs: {:ok, %{"logs" => entries}}} = assigns)
       when is_list(entries) do
    assigns = assign(assigns, :line_count, length(entries))

    ~H"""
    <.panel title="Slot output">
      <:meta>
        <span class="font-mono">{line_count_label(@line_count)}</span>
      </:meta>
      <.empty_state
        icon="hero-eye-slash"
        msg="Raw slot output hidden in privacy mode."
        hint={"#{line_count_label(@line_count)} suppressed."}
      />
    </.panel>
    """
  end

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

  defp selection_rows(snapshot, selected) do
    rows = sessions(snapshot)

    # The SELECTED session must survive snapshot churn: a slot recycled
    # between polls drops out of the next snapshot, and rebuilding the option
    # list without it silently reset the operator's choice. Opaque stable
    # tokens let the same fallback work in privacy mode.
    if is_binary(selected) and selected != "" and
         not Enum.any?(rows, &(&1["session_id"] == selected)) do
      rows ++ [%{"session_id" => selected, "agent" => "not in latest snapshot"}]
    else
      rows
    end
  end

  defp session_options(snapshot, selected, privacy?) do
    rows = selection_rows(snapshot, selected)
    lookup = DashHooks.inspect_lookup(%{"sessions" => rows})

    rows
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      sid = s["session_id"]

      %{
        value: DashHooks.inspect_value(lookup, privacy?, sid),
        label:
          if(privacy?,
            do: "session #{i + 1} (#{PrivacyRedactor.mask_cid(s["agent"])})",
            else: "#{sid} (#{s["agent"]})"
          ),
        selected: selected == sid
      }
    end)
  end

  defp resolve_session_id(_socket, ""), do: nil

  defp resolve_session_id(socket, submitted) do
    lookup =
      DashHooks.inspect_lookup(%{
        "sessions" => selection_rows(socket.assigns[:snapshot], socket.assigns.selected)
      })

    DashHooks.resolve_inspect_value(lookup, submitted)
  end

  defp line_count_label(1), do: "1 line"
  defp line_count_label(n), do: "#{n} lines"
end
