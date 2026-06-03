defmodule SubzeroSwarmDashboard.SwarmFeed do
  @moduledoc """
  Polls the swarm `/dashboard` aggregate every `poll_interval_ms` and republishes
  snapshots over the app's `Phoenix.PubSub` (topic `"feed"`). The Slipstream WS
  client (`SwarmFeed.Socket`) publishes live `{:event, ...}` on the same topic;
  LiveViews subscribe to `"feed"`.

  Silent-empty guard (spec §5 C1/R3): if a snapshot reports agents but no WS event
  has arrived for a while, broadcast `{:warning, :endpoint_not_colocated}` — the
  classic "API not co-located with the swarm BEAM" failure.

  Messages broadcast on `"feed"`:
    - `{:snapshot, map}` — a fresh `/dashboard` aggregate
    - `{:disconnected, reason}` — the swarm is unreachable
    - `{:event, type, payload}` — a live WS event (from `SwarmFeed.Socket`)
    - `{:warning, :endpoint_not_colocated}`
  """
  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias SubzeroSwarmDashboard.SwarmClient

  @pubsub SubzeroSwarmDashboard.PubSub
  @topic "feed"
  @silent_after_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Topic LiveViews subscribe to."
  def topic, do: @topic
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @impl true
  def init(_opts) do
    PubSub.subscribe(@pubsub, @topic)
    interval = Application.get_env(:subzero_swarm_dashboard, :poll_interval_ms, 3_000)
    swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    send(self(), :poll)

    {:ok,
     %{
       interval: interval,
       swarm: swarm,
       last_snapshot: nil,
       last_event_at: nil,
       started_at: now_ms()
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case SwarmClient.dashboard(state.swarm) do
        {:ok, snap} ->
          PubSub.broadcast(@pubsub, @topic, {:snapshot, snap})
          maybe_warn_silent(snap, state)
          %{state | last_snapshot: snap}

        {:error, reason} ->
          PubSub.broadcast(@pubsub, @topic, {:disconnected, reason})
          state
      end

    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  # Observe live WS events (from the Socket) to feed the silent-empty guard.
  def handle_info({:event, _type, _payload}, state),
    do: {:noreply, %{state | last_event_at: now_ms()}}

  # Ignore our own broadcasts echoed back to us.
  def handle_info({:snapshot, _}, state), do: {:noreply, state}
  def handle_info({:disconnected, _}, state), do: {:noreply, state}
  def handle_info({:warning, _}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_warn_silent(snap, state) do
    agents = get_in(snap, ["summary", "agents"]) || 0
    running_ms = now_ms() - state.started_at
    silent? = is_nil(state.last_event_at) or now_ms() - state.last_event_at > @silent_after_ms

    if agents > 0 and running_ms > @silent_after_ms and silent? do
      PubSub.broadcast(@pubsub, @topic, {:warning, :endpoint_not_colocated})
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
