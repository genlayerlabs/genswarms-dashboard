defmodule SubzeroSwarmDashboardWeb.DashHooks do
  @moduledoc """
  `on_mount` hook shared by every dashboard LiveView. Subscribes to the `SwarmFeed`
  PubSub and centralizes the feed messages (`{:snapshot}`/`{:disconnected}`/
  `{:warning}`) via an attached `handle_info` hook, so pages only render `@snapshot`.
  Live `{:event, ...}` messages fall through (`:cont`) for pages that want them.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias SubzeroSwarmDashboard.SwarmFeed

  def on_mount(:default, _params, _session, socket) do
    swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    if connected?(socket), do: SwarmFeed.subscribe()

    socket =
      socket
      |> assign_new(:snapshot, fn -> nil end)
      |> assign_new(:conn_status, fn -> :connecting end)
      |> assign_new(:feed_warning, fn -> nil end)
      |> assign(:swarm, swarm)
      |> attach_hook(:dash_feed, :handle_info, &handle_feed/2)

    {:cont, socket}
  end

  # {:cont} so pages that need a side-effect on new snapshots (e.g. Topology pushing
  # the graph to its JS hook) can also react; @snapshot is assigned here regardless.
  defp handle_feed({:snapshot, snap}, socket),
    do: {:cont, assign(socket, snapshot: snap, conn_status: :connected)}

  defp handle_feed({:disconnected, _reason}, socket),
    do: {:halt, assign(socket, conn_status: :disconnected)}

  defp handle_feed({:warning, w}, socket),
    do: {:halt, assign(socket, feed_warning: w)}

  # v1: 3s snapshots drive the UI; live WS events are observed by SwarmFeed for the
  # silent-empty guard but not pushed into pages here.
  defp handle_feed({:event, _type, _payload}, socket), do: {:halt, socket}

  # Non-feed messages (e.g. a page's own :load_usage) pass through to the LiveView.
  defp handle_feed(_other, socket), do: {:cont, socket}
end
