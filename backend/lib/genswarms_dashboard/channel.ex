defmodule GenswarmsDashboard.Channel do
  @moduledoc """
  READ-ONLY relay of the swarm's live event feed. Subscribes to the injected `pubsub_server`
  (the host passes the engine's PubSub — same BEAM, the engine publishes regardless of whether
  its web server runs) and pushes the same event names/payloads the dashboard consumes.

  Deliberately has NO meaningful `handle_in` (no send_task, no subscribe_logs) — the dashboard's
  Slipstream client is a passive relay. No write path, no task injection.
  """
  use Phoenix.Channel

  @heartbeat_ms_default 5_000

  @relayed_events ~w(heartbeat agent_status message_routed message_broadcast agent_added
                     agent_removed topology_changed agent_output swarm_started swarm_stopped)

  @doc "The pinned WS event-name contract (golden-tested; the frontend consumes these)."
  def relayed_events, do: @relayed_events

  @impl true
  def join("swarm:" <> swarm_name, _params, socket) do
    # Succeed for the live swarm; a hard {:error,...} would make Slipstream reconnect-loop forever.
    case swarm_status(swarm_name) do
      {:ok, _} ->
        join_ok(swarm_name, socket)

      {:error, :not_found} ->
        {:error, %{reason: "swarm_not_found"}}

      # SwarmManager.status timed out (it is a GenServer.call that blocks behind in-flight
      # docker ops — the head-of-line stall). A timeout means the swarm is UP but busy, not
      # gone, so we must NOT hard-error here (that triggers the reconnect-loop noted above).
      # Join and relay via PubSub anyway — the event feed flows independently of status.
      {:error, :unavailable} ->
        join_ok(swarm_name, socket)
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  defp join_ok(swarm_name, socket) do
    pubsub = GenswarmsDashboard.Config.get(:pubsub_server)
    Phoenix.PubSub.subscribe(pubsub, "swarm:#{swarm_name}")
    Phoenix.PubSub.subscribe(pubsub, "swarm:#{swarm_name}:output")
    Phoenix.PubSub.subscribe(pubsub, "swarm:#{swarm_name}:routing")
    Phoenix.PubSub.subscribe(pubsub, "swarm:#{swarm_name}:status")
    # Heartbeat: a low-traffic swarm can sit idle for minutes, which would trip the
    # dashboard's "no WS event in 15s → not co-located" guard even though the relay is fine.
    Process.send_after(self(), :heartbeat, heartbeat_ms())
    {:ok, %{swarm: swarm_name}, assign(socket, :swarm_name, swarm_name)}
  end

  # SwarmManager.status is a 5s GenServer.call; it can :exit (timeout) when SwarmManager is
  # blocked behind an in-flight docker op. Guard the exit so a status hiccup degrades the join
  # to "up but busy" (relay anyway) instead of crashing the channel and reconnect-looping.
  defp swarm_status(swarm_name) do
    Genswarms.SwarmManager.status(swarm_name)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # The dashboard is a passive relay — ignore anything it might send (no write path).
  @impl true
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:heartbeat, socket) do
    push(socket, "heartbeat", %{at: System.os_time(:millisecond)})
    Process.send_after(self(), :heartbeat, heartbeat_ms())
    {:noreply, socket}
  end

  # ── PubSub → client pushes (same names/payloads as the engine channel) ──────────
  def handle_info({:agent_status, agent, state}, socket) do
    push(socket, "agent_status", %{agent: agent, state: state})
    {:noreply, socket}
  end

  def handle_info({:message_routed, data}, socket) do
    push(socket, "message_routed", data)
    {:noreply, socket}
  end

  def handle_info({:message_broadcast, data}, socket) do
    push(socket, "message_broadcast", data)
    {:noreply, socket}
  end

  def handle_info({:agent_added, _swarm, name, spec}, socket) do
    push(socket, "agent_added", %{name: to_string(name), spec: serialize_spec(spec)})
    {:noreply, socket}
  end

  def handle_info({:agent_removed, _swarm, name}, socket) do
    push(socket, "agent_removed", %{name: to_string(name)})
    {:noreply, socket}
  end

  def handle_info({:topology_changed, _swarm}, socket) do
    push(socket, "topology_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:agent_output, agent, content}, socket) do
    push(socket, "agent_output", %{agent: agent, content: content})
    {:noreply, socket}
  end

  def handle_info({:swarm_started, _name, status}, socket) do
    push(socket, "swarm_started", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info({:swarm_stopped, _name}, socket) do
    push(socket, "swarm_stopped", %{})
    {:noreply, socket}
  end

  # ignore everything else on the PubSub topics (log_event, etc. — dashboard polls HTTP for those)
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp heartbeat_ms, do: GenswarmsDashboard.Config.get(:heartbeat_ms, @heartbeat_ms_default)

  # ── spec serialization (same as the engine channel) ─────────────────────────────
  defp serialize_spec(spec) when is_map(spec),
    do: Map.new(spec, fn {k, v} -> {to_string(k), serialize_spec_value(v)} end)

  defp serialize_spec(spec), do: inspect(spec)

  defp serialize_spec_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp serialize_spec_value(v) when is_list(v), do: Enum.map(v, &serialize_spec_value/1)
  defp serialize_spec_value(v) when is_map(v), do: serialize_spec(v)
  defp serialize_spec_value(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&serialize_spec_value/1)
  defp serialize_spec_value(v), do: v
end
