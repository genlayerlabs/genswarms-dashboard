defmodule SubzeroSwarmDashboard.SwarmFeed.Socket do
  @moduledoc """
  Slipstream client that joins the swarm's `swarm:<name>` channel and republishes
  every live event as `{:event, type, payload}` on the app PubSub topic `"feed"`.
  Best-effort: if the swarm is down it reconnects; failures never crash the app.
  """
  use Slipstream
  require Logger

  alias Phoenix.PubSub

  @pubsub SubzeroSwarmDashboard.PubSub
  @feed "feed"

  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Slipstream
  def init(_opts), do: {:ok, connect!(uri: ws_uri())}

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, "swarm:#{swarm_name()}")}
  end

  @impl Slipstream
  def handle_message(_topic, event, payload, socket) do
    PubSub.broadcast(@pubsub, @feed, {:event, event, payload})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  # ── config ───────────────────────────────────────────────────────────────────
  defp ws_uri do
    base =
      Application.get_env(:subzero_swarm_dashboard, :swarm_ws_url) ||
        Application.fetch_env!(:subzero_swarm_dashboard, :swarm_api_url)

    build_uri(base, Application.get_env(:subzero_swarm_dashboard, :swarm_api_token))
  end

  @doc false
  def build_uri(base, token) do
    uri =
      base
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")
      |> String.trim_trailing("/")
      |> Kernel.<>("/swarm/websocket")

    if token in [nil, ""], do: uri, else: uri <> "?token=" <> token
  end

  defp swarm_name, do: Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
end
