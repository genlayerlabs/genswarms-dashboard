defmodule SubzeroSwarmDashboardWeb.DashHooks do
  @moduledoc """
  `on_mount` hook shared by every dashboard LiveView. Subscribes to the `SwarmFeed`
  PubSub and centralizes the feed messages (`{:snapshot}`/`{:disconnected}`/
  `{:warning}`) via an attached `handle_info` hook, so pages only render `@snapshot`.
  Live `{:event, ...}` messages fall through (`:cont`) for pages that want them.

  Same pattern for the display-event feed (`EventsFeed`, topic `"events"`):
  `{:story, summary}` is centralized into `@story`; raw `{:display_event, ...}`
  falls through for pages that consume them (Topology canvas).
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.SwarmFeed
  alias SubzeroSwarmDashboard.SwarmClient

  def on_mount(:default, _params, _session, socket) do
    swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")

    if connected?(socket) do
      SwarmFeed.subscribe()
      EventsFeed.subscribe()
    end

    # Seed from the feeds' caches so a fresh mount (page load, refresh, live nav)
    # renders the full menu + page immediately — without this, every view opened
    # with nil assigns and flashed the empty state ("Extension unavailable",
    # incomplete menu) for up to one poll interval (3s).
    cached_snapshot = SwarmFeed.current()
    dashboard_title = dashboard_title(cached_snapshot, swarm)

    socket =
      socket
      |> assign_new(:snapshot, fn -> cached_snapshot end)
      |> assign_new(:conn_status, fn -> if(cached_snapshot, do: :connected, else: :connecting) end)
      |> assign_new(:feed_warning, fn -> nil end)
      |> assign_new(:dashboard_title, fn -> dashboard_title end)
      |> assign_new(:story, fn -> EventsFeed.current_story() end)
      # the shared slide-over inspector (any page can open it via phx-click="inspect")
      |> assign_new(:inspect, fn -> nil end)
      |> assign_new(:inspect_transcript, fn -> nil end)
      |> assign_new(:inspect_activity, fn -> nil end)
      |> assign(:swarm, swarm)
      |> attach_hook(:dash_feed, :handle_info, &handle_feed/2)
      |> attach_hook(:dash_inspect_evt, :handle_event, &handle_inspect_event/3)
      |> attach_hook(:dash_inspect_info, :handle_info, &handle_inspect_info/2)

    {:cont, socket}
  end

  # ── shared inspector: open on any page, close on Esc / click-away ────────────
  defp handle_inspect_event("inspect", %{"session_id" => sid}, socket)
       when is_binary(sid) and sid != "" do
    case find_session(socket.assigns[:snapshot], sid) do
      nil ->
        {:halt, socket}

      session ->
        if connected?(socket), do: send(self(), {:load_inspect_detail, sid})

        {:halt,
         assign(socket,
           inspect: session,
           inspect_transcript: :loading,
           inspect_activity: :loading
         )}
    end
  end

  defp handle_inspect_event("inspect_close", _params, socket),
    do: {:halt, assign(socket, inspect: nil, inspect_transcript: nil, inspect_activity: nil)}

  # Not an inspector event — let the page's own handle_event run.
  defp handle_inspect_event(_event, _params, socket), do: {:cont, socket}

  # Lazily fetch the full session detail (durable transcript + raw slot activity),
  # so the inspector shows everything the dedicated page does. Ignore if the user
  # already moved on (closed it or opened a different session).
  defp handle_inspect_info({:load_inspect_detail, sid}, socket) do
    swarm = socket.assigns.swarm
    transcript = SwarmClient.session_history(swarm, sid)
    activity = SwarmClient.session_logs(swarm, sid)

    if socket.assigns[:inspect] && socket.assigns.inspect["session_id"] == sid do
      {:halt, assign(socket, inspect_transcript: transcript, inspect_activity: activity)}
    else
      {:halt, socket}
    end
  end

  # Per-snapshot inspector refresh: the ephemeral slot activity is THE live panel,
  # so it re-fetches every tick; the durable transcript only changes when the
  # session actually moved, so it re-fetches only when the roster row did.
  defp handle_inspect_info({:refresh_inspect, sid, row_changed?}, socket) do
    if socket.assigns[:inspect] && socket.assigns.inspect["session_id"] == sid do
      swarm = socket.assigns.swarm
      socket = assign(socket, inspect_activity: SwarmClient.session_logs(swarm, sid))

      socket =
        if row_changed?,
          do: assign(socket, inspect_transcript: SwarmClient.session_history(swarm, sid)),
          else: socket

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_inspect_info(_msg, socket), do: {:cont, socket}

  defp find_session(%{"sessions" => sessions}, sid) when is_list(sessions),
    do: Enum.find(sessions, &(&1["session_id"] == sid))

  defp find_session(_snapshot, _sid), do: nil

  # {:cont} so pages that need a side-effect on new snapshots (e.g. Topology pushing
  # the graph to its JS hook) can also react; @snapshot is assigned here regardless.
  defp handle_feed({:snapshot, snap}, socket) do
    socket =
      assign(socket,
        snapshot: snap,
        conn_status: :connected,
        dashboard_title: dashboard_title(snap, socket.assigns[:swarm])
      )

    # Keep the open inspector live: its header follows the fresh roster row, and
    # {:refresh_inspect} re-fetches the detail (activity always, transcript only
    # on a row change) without a loading flash.
    socket =
      with %{"session_id" => sid} = prev <- socket.assigns[:inspect],
           %{} = fresh <- find_session(snap, sid) do
        if connected?(socket), do: send(self(), {:refresh_inspect, sid, fresh != prev})
        assign(socket, inspect: fresh)
      else
        _ -> socket
      end

    {:cont, socket}
  end

  defp handle_feed({:disconnected, _reason}, socket),
    do: {:halt, assign(socket, conn_status: :disconnected)}

  defp handle_feed({:warning, w}, socket),
    do: {:halt, assign(socket, feed_warning: w)}

  # {:cont} like {:snapshot}: the Events page stream-prepends new story rows in
  # its own handle_info; @story is assigned here regardless.
  defp handle_feed({:story, summary}, socket),
    do: {:cont, assign(socket, story: summary)}

  # Raw display events flow through to pages that consume them (Topology canvas).
  defp handle_feed({:display_event, _ev}, socket), do: {:cont, socket}

  # Live WS events flow through to pages (every page has a catch-all handle_info/2;
  # Topology consumes them for instant graph updates). SwarmFeed also observes them
  # (it subscribes to "feed") for the silent-empty guard.
  # Non-feed messages (e.g. a page's own :load_usage) also pass through.
  defp handle_feed(_other, socket), do: {:cont, socket}

  defp dashboard_title(%{"dashboard_title" => title} = snapshot, swarm) when is_binary(title) do
    case String.trim(title) do
      "" -> dashboard_title(Map.delete(snapshot, "dashboard_title"), swarm)
      title -> title
    end
  end

  defp dashboard_title(%{"swarm" => swarm}, _swarm), do: titleize_swarm(swarm)
  defp dashboard_title(_snapshot, swarm), do: titleize_swarm(swarm)

  defp titleize_swarm(swarm) do
    swarm
    |> to_string()
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    |> case do
      "" -> "Swarm Console"
      title -> title
    end
  end
end
