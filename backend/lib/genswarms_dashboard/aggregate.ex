defmodule GenswarmsDashboard.Aggregate do
  @moduledoc """
  Generic, app-agnostic dashboard aggregate. Builds the envelope
  `%{swarm, dashboard_title, status, uptime_s, generated_at, data_source, summary, nodes,
  edges, sessions, extensions, warnings}` from engine status/topology plus host-provided
  session rows and extension blocks (`GenswarmsDashboard.DataSource`). The live overlay
  (active/idle, agent slot, last_activity) comes from the host's `pool_snapshot`.

  Knows ZERO transport specifics: session rows pass through with mandatory safe defaults
  (`transport: "unknown"`, `transport_ref: %{}`, `metadata: %{}` — never nil).
  """

  alias GenswarmsDashboard.Config

  @default_label "genswarms"

  # ── live wrapper (pinned by tests in the next task) ─────────────────────────
  @spec build(String.t()) :: {:ok, map()} | {:error, :not_found}
  def build(swarm_name) do
    case swarm_status(swarm_name) do
      {:ok, status} ->
        ds = Config.get(:data_source)
        snap = ds.snapshot(swarm_name)

        data = %{
          sessions: snap.sessions,
          extensions: snap.extensions,
          pool: ds.pool_snapshot(swarm_name),
          fabricate: fabricator(ds),
          dashboard_title:
            clean_title(Config.get(:dashboard_title)) || titleize_swarm(swarm_name),
          label: Config.get(:data_source_label, @default_label)
        }

        {:ok, assemble(status, topology_for(swarm_name), data, DateTime.utc_now())}

      {:error, reason} ->
        # :not_found (unknown swarm) or :unavailable (status timed out — SwarmManager
        # blocked behind an in-flight docker op; degrade, don't crash the API to 500).
        {:error, reason}
    end
  end

  # SwarmManager.status is a 5s GenServer.call; it can time out when SwarmManager is
  # blocked behind a docker operation (e.g. a cold-spawn `docker run`). Guard the exit
  # so the aggregate degrades to :unavailable instead of crashing the read API.
  defp swarm_status(swarm_name) do
    Genswarms.SwarmManager.status(swarm_name)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp fabricator(ds) do
    if Code.ensure_loaded?(ds) and function_exported?(ds, :fabricate_session, 1),
      do: &ds.fabricate_session/1,
      else: &default_session/1
  end

  defp topology_for(swarm_name) do
    case Genswarms.Routing.Router.get_topology(swarm_name) do
      {:ok, adj} when is_map(adj) -> adj_to_edges(adj)
      %{} = adj -> adj_to_edges(adj)
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp adj_to_edges(adj),
    do: Enum.map(adj, fn {from, targets} -> %{from: from, targets: List.wrap(targets)} end)

  # ── pure aggregation (no engine, no host — unit-testable) ────────────────────
  @doc """
  Build the aggregate from already-gathered `data`:
  `%{sessions: [row], extensions: %{String.t() => map}, pool: %{assigned, last_seen, leased, size},
  fabricate: (cid -> row) [optional], label: String.t() [optional]}`. Pure — unit-testable.
  """
  @spec assemble(map(), list(), map(), DateTime.t()) :: map()
  def assemble(status, topology, data, now) do
    %{sessions: rows, extensions: extensions, pool: pool} = data
    fabricate = Map.get(data, :fabricate) || (&default_session/1)
    sessions = build_sessions(rows, pool, fabricate)

    %{
      swarm: status.name,
      dashboard_title:
        clean_title(Map.get(data, :dashboard_title)) || titleize_swarm(status.name),
      status: to_string(status.status),
      uptime_s: uptime(status, now),
      generated_at: now,
      data_source: Map.get(data, :label) || @default_label,
      summary: %{
        agents: length(status.agents),
        objects: length(status.objects),
        sessions: length(sessions),
        pool: %{leased: Map.get(pool, :leased, 0), size: Map.get(pool, :size, 0)}
      },
      nodes: classify_nodes(status),
      edges: normalize_edges(topology),
      sessions: sessions,
      extensions: extensions,
      warnings: []
    }
  end

  @doc "The fully-defaulted generic session row for a pool-only cid (no host override)."
  @spec default_session(String.t()) :: map()
  def default_session(cid) do
    %{
      session_id: cid,
      label: nil,
      transport: "unknown",
      transport_ref: %{},
      user: nil,
      metadata: %{},
      last_activity: nil
    }
  end

  # ── sessions: union of durable rows + currently-leased live cids ─────────────
  # Row order is preserved as the wire `sessions` array order (adapter-controlled);
  # fabricated pool-only rows are appended. Duplicate session_ids are dropped
  # (first row wins) — the legacy map-keyed aggregate guaranteed uniqueness for free.
  defp build_sessions(rows, pool, fabricate) do
    rows = Enum.uniq_by(rows, & &1.session_id)
    assigned = Map.get(pool, :assigned, %{})
    pool_seen = Map.get(pool, :last_seen, %{})
    durable_cids = MapSet.new(rows, & &1.session_id)

    pool_only =
      for cid <- Map.keys(assigned), not MapSet.member?(durable_cids, cid), do: fabricate.(cid)

    Enum.map(rows ++ pool_only, fn row ->
      cid = row.session_id
      row = with_defaults(row, cid)
      slot = Map.get(assigned, cid)

      Map.merge(row, %{
        agent: slot && to_string(slot),
        state: if(slot, do: "active", else: "idle"),
        last_activity: Map.get(pool_seen, cid) || row.last_activity
      })
    end)
  end

  # Mandatory safe defaults: fill missing keys AND replace explicit nils for the
  # never-nil keys, so a transport-free host still yields valid values everywhere.
  defp with_defaults(row, cid) do
    default_session(cid)
    |> Map.merge(row)
    |> Map.put(:session_id, cid)
    |> ensure(:transport, "unknown")
    |> ensure(:transport_ref, %{})
    |> ensure(:metadata, %{})
  end

  defp ensure(row, key, default) do
    if is_nil(Map.get(row, key)), do: Map.put(row, key, default), else: row
  end

  defp uptime(%{started_at: %DateTime{} = t}, now), do: DateTime.diff(now, t)
  defp uptime(_, _), do: nil

  defp clean_title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      title -> title
    end
  end

  defp clean_title(nil), do: nil
  defp clean_title(value), do: value |> to_string() |> clean_title()

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

  # ── nodes / edges (generic swarm shape, same as the engine aggregate) ────────
  defp classify_nodes(status) do
    objects =
      Enum.map(status.objects, fn o ->
        %{name: to_string(o.name), type: "object", subtype: subtype(o[:handler])}
      end)

    agents = Enum.map(status.agents, &agent_node/1)

    objects ++ agents
  end

  defp agent_node(agent) do
    %{name: to_string(agent.name), type: "agent", state: to_string(agent.state)}
    |> maybe_put_backend(agent)
  end

  defp maybe_put_backend(node, agent) do
    case backend_value(agent) do
      {:ok, nil} -> node
      {:ok, backend} -> Map.put(node, :backend, safe_backend(backend))
      :error -> node
    end
  end

  defp backend_value(agent) do
    cond do
      Map.has_key?(agent, :backend) -> {:ok, Map.get(agent, :backend)}
      Map.has_key?(agent, "backend") -> {:ok, Map.get(agent, "backend")}
      true -> :error
    end
  end

  @doc "Project a live backend spec to the public dashboard-safe shape."
  def safe_backend({:bwrap, opts}) when is_map(opts),
    do: %{type: "bwrap", opts: safe_backend_opts(opts)}

  def safe_backend(:bwrap), do: %{type: "bwrap", opts: %{}}
  def safe_backend(backend) when is_atom(backend), do: to_string(backend)
  def safe_backend(backend) when is_binary(backend), do: backend
  def safe_backend(other), do: inspect(other)

  @doc "Project a live agent spec to the public dashboard-safe shape."
  def safe_agent_spec(%{} = spec) do
    [:name, :model, :backend]
    |> Enum.reduce(%{}, fn key, acc ->
      case safe_agent_spec_value(key, get_any(spec, key)) do
        nil -> acc
        value -> Map.put(acc, to_string(key), value)
      end
    end)
  end

  def safe_agent_spec(_spec), do: %{}

  @doc "Project LogStore metadata to the public dashboard-safe shape."
  def safe_event_metadata(%{} = metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      if safe_metadata_key?(key) do
        # buffer_tail is crash output — it legitimately contains paths ("/dev/fuse"),
        # which the generic string filter rejects wholesale. Redact the secret-shaped
        # substrings instead of dropping the whole diagnostic.
        safe_value =
          if key == "buffer_tail",
            do: safe_tail_value(value),
            else: safe_public_value(value)

        case safe_value do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      else
        acc
      end
    end)
  end

  def safe_event_metadata(_metadata), do: %{}

  defp safe_agent_spec_value(:backend, nil), do: nil

  defp safe_agent_spec_value(:backend, backend),
    do: backend |> safe_backend() |> stringify_public_keys()

  defp safe_agent_spec_value(_key, value), do: safe_public_value(value)

  defp get_any(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # exit_status + buffer_tail are the agent_stopped crash forensics (the port's
  # exit code and the dying process's last output) — without them the operator
  # sees a bare "agent stopped" and has to reach for kubectl. buffer_tail still
  # passes through unsafe_public_string? like every other string value.
  defp safe_metadata_key?(key),
    do: key in ~w(action agent from kind reason source slot state status to type exit_status buffer_tail)

  defp safe_public_value(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  defp safe_public_value(value) when is_binary(value) do
    if unsafe_public_string?(value), do: nil, else: value
  end

  defp safe_public_value(value) when is_boolean(value), do: value
  defp safe_public_value(value) when is_integer(value), do: value
  defp safe_public_value(value) when is_float(value), do: value
  defp safe_public_value(_value), do: nil

  defp unsafe_public_string?(value) do
    String.contains?(value, ["/", "://", "sk-", "Bearer ", "tg:"]) or
      Regex.match?(~r/0x[0-9a-fA-F]{40}/, value)
  end

  # buffer_tail keeps its paths (they ARE the diagnostic) but never ships
  # secret- or identity-shaped substrings.
  defp safe_tail_value(value) when is_binary(value) do
    value
    |> String.replace(~r/sk-[A-Za-z0-9_-]{8,}/, "sk-…")
    |> String.replace(~r/Bearer\s+\S+/, "Bearer …")
    |> String.replace(~r/tg:[0-9:]+/, "tg:…")
    |> String.replace(~r/0x[0-9a-fA-F]{40}/, "0x…")
  end

  defp safe_tail_value(_value), do: nil

  defp stringify_public_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_public_keys(value)} end)
  end

  defp stringify_public_keys(value), do: value

  # Backend specs can carry host paths or credentials. The dashboard only needs
  # the resource caps that explain bwrap pool behavior.
  defp safe_backend_opts(opts) do
    opts
    |> Map.take([
      :memory_limit,
      :cpu_shares,
      :tasks_max,
      "memory_limit",
      "cpu_shares",
      "tasks_max"
    ])
    |> Map.new(fn {key, value} -> {key, safe_backend_value(value)} end)
  end

  defp safe_backend_value(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  defp safe_backend_value(value) when is_tuple(value), do: inspect(value)
  defp safe_backend_value(value), do: value

  defp subtype(nil), do: nil
  defp subtype(handler), do: handler |> Module.split() |> List.last() |> Macro.underscore()

  defp normalize_edges(topology) do
    Enum.flat_map(topology, fn
      %{from: from, targets: targets} ->
        Enum.map(targets, fn to -> %{from: to_string(from), to: to_string(to)} end)

      %{from: from, to: to} ->
        [%{from: to_string(from), to: to_string(to)}]
    end)
  end
end
