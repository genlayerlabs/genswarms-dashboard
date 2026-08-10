defmodule SubzeroSwarmDashboard.FleetCatalog do
  @moduledoc """
  Small cached catalog of every swarm exposed by the shared dashboard backend.

  The endpoint is polled independently from any selected swarm, so a newly cast
  project appears in the selector without restarting the Phoenix frontend.
  """

  use GenServer

  alias Phoenix.PubSub
  alias SubzeroSwarmDashboard.SwarmClient

  @pubsub SubzeroSwarmDashboard.PubSub
  @topic "fleet"
  @poll_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  def current do
    GenServer.call(__MODULE__, :current, 1_000)
  catch
    :exit, _ -> fallback()
  end

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, fallback()}
  end

  @impl true
  def handle_call(:current, _from, swarms), do: {:reply, swarms, swarms}

  @impl true
  def handle_info(:poll, current) do
    swarms =
      case SwarmClient.swarms() do
        {:ok, rows} -> normalize(rows)
        {:error, _reason} -> current
      end

    if swarms != current, do: PubSub.broadcast(@pubsub, @topic, {:swarms, swarms})
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, swarms}
  end

  defp normalize(rows) do
    names =
      Enum.flat_map(rows, fn
        %{"name" => name} when is_binary(name) and name != "" -> [name]
        %{name: name} when is_binary(name) and name != "" -> [name]
        name when is_binary(name) and name != "" -> [name]
        _ -> []
      end)

    (fallback() ++ names) |> Enum.uniq() |> Enum.sort()
  end

  defp fallback do
    [Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")]
  end
end
