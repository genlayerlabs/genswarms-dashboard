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
  def init(_opts) do
    # The read token rides in the x-dashboard-token HEADER, not the URL query
    # string — so the secret can't leak via access/proxy logs or a Referer.
    token = Application.get_env(:subzero_swarm_dashboard, :swarm_api_token)
    {:ok, connect!(uri: ws_uri(), headers: auth_headers(token))}
  end

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

    build_uri(base)
  end

  @doc "The ws(s) URI for the swarm socket. The token is NOT here — it's a header."
  def build_uri(base) do
    base
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> String.trim_trailing("/")
    |> Kernel.<>("/swarm/websocket")
  end

  @doc "Read-token header for the WS upgrade, or [] when no token is configured."
  def auth_headers(token) when token in [nil, ""], do: []
  def auth_headers(token), do: [{"x-dashboard-token", token}]

  defp swarm_name, do: Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
end
