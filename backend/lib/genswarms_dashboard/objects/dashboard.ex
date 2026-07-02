defmodule GenswarmsDashboard.Objects.Dashboard do
  @moduledoc """
  GenSwarms object handler that owns the dashboard endpoint's lifecycle.

  Declares the dashboard as swarm DATA instead of a boot-script ritual: the
  swarm definition lists it under `objects:`, the ObjectServer supervises it
  (a crash restarts the object, which restarts the endpoint), and teardown is
  deterministic (`terminate/2` stops the listener).

      %{
        name: :dashboard,
        handler: GenswarmsDashboard.Objects.Dashboard,
        config: %{
          swarm: "my-swarm",                          # required
          port: 4001,
          token: "…",                                  # or GENSWARMS_DASHBOARD_TOKEN
          data_source: MyApp.DashboardSource,          # default: DataSource.Null
          events_source: MyApp.EventFeedSource,        # optional
          pubsub_server: Genswarms.PubSub              # default
        }
      }

  Config is pure data: module refs may arrive as atoms (Elixir swarm defs) or
  strings (JSON IR) — strings resolve via `String.to_existing_atom` (no atom
  minting; an unknown module fails init, fail-closed). With no `data_source`
  the endpoint boots on `DataSource.Null` (engine-only pages work, sessions
  empty), so the object is usable with zero host code.

  Implements the `Genswarms.Objects.ObjectHandler` callbacks BY CONVENTION —
  no `@behaviour`, because genswarms is a peer/runtime dependency (same
  pattern as genswarms-telegram's objects; this library compiles without the
  engine).

  Limitation: ONE dashboard object per BEAM — the runtime config lives in a
  single `GenswarmsDashboard.Config` slot and the endpoint module is global.
  """

  require Logger

  # ObjectHandler init/1: resolve config, start the endpoint, keep its pid.
  def init(config) when is_map(config) do
    with {:ok, swarm} <- fetch_swarm(config),
         {:ok, data_source} <-
           resolve_module(Map.get(config, :data_source, GenswarmsDashboard.DataSource.Null)),
         {:ok, events_source} <- resolve_optional_module(Map.get(config, :events_source)),
         {:ok, pubsub} <- resolve_module(Map.get(config, :pubsub_server, Genswarms.PubSub)) do
      opts =
        [
          swarm: swarm,
          data_source: data_source,
          events_source: events_source,
          pubsub_server: pubsub,
          token: Map.get(config, :token) || System.get_env("GENSWARMS_DASHBOARD_TOKEN"),
          port: Map.get(config, :port, 4001),
          secret_key_base:
            Map.get(config, :secret_key_base) || System.get_env("DASHBOARD_SECRET_KEY_BASE")
        ] ++ passthrough(config, [:host, :dashboard_title, :data_source_label, :heartbeat_ms])

      case GenswarmsDashboard.start(opts) do
        {:ok, pid} ->
          Logger.info("[dashboard] listening: #{GenswarmsDashboard.describe()}")
          {:ok, %{endpoint: pid, swarm: swarm, data_source: data_source}}

        {:error, reason} ->
          {:error, {:dashboard_start_failed, reason}}
      end
    end
  end

  def init(_config), do: {:error, :config_must_be_a_map}

  # ObjectHandler handle_message/3: a tiny JSON protocol; always replies with a
  # well-formed envelope so a routed agent never sees a silent drop.
  def handle_message(_from, content, state) do
    reply =
      case Jason.decode(content) do
        {:ok, %{"action" => "status"}} ->
          %{
            ok: true,
            listening: GenswarmsDashboard.describe(),
            swarm: state.swarm,
            data_source: inspect(state.data_source),
            endpoint_alive: is_pid(state.endpoint) and Process.alive?(state.endpoint)
          }

        {:ok, %{"action" => other}} ->
          %{ok: false, error: "unknown_action", action: other, supported: ["status"]}

        _ ->
          %{ok: false, error: "bad_json", supported: ["status"]}
      end

    {:reply, Jason.encode!(reply), state}
  end

  # ObjectHandler interface/0 (shown by swarm-msg / dashboards).
  def interface do
    %{
      status: %{
        input: ~s({"action":"status"}),
        output: "JSON: {ok, listening, swarm, data_source, endpoint_alive}"
      }
    }
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ObjectHandler terminate/2: normal exits do not propagate through the link,
  # so stop the endpoint explicitly — no leaked listener after a clean stop.
  # Unlink first: the endpoint is linked to the process that ran init/1, and the
  # :shutdown we send would otherwise propagate back and kill it mid-terminate.
  def terminate(_reason, %{endpoint: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp fetch_swarm(config) do
    case Map.get(config, :swarm) do
      s when is_binary(s) and s != "" -> {:ok, s}
      s when is_atom(s) and not is_nil(s) -> {:ok, to_string(s)}
      _ -> {:error, :missing_swarm}
    end
  end

  defp resolve_optional_module(nil), do: {:ok, nil}
  defp resolve_optional_module(mod), do: resolve_module(mod)

  defp resolve_module(mod) when is_atom(mod) and not is_nil(mod), do: {:ok, mod}

  defp resolve_module(name) when is_binary(name) do
    {:ok, String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))}
  rescue
    ArgumentError -> {:error, {:unknown_module, name}}
  end

  defp resolve_module(other), do: {:error, {:unknown_module, other}}

  defp passthrough(config, keys) do
    for key <- keys, (value = Map.get(config, key)) != nil, do: {key, value}
  end
end
