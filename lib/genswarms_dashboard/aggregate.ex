defmodule GenswarmsDashboard.Aggregate do
  @moduledoc """
  Generic, app-agnostic dashboard aggregate. Builds the envelope
  `%{swarm, status, uptime_s, generated_at, data_source, summary, nodes, edges, sessions,
  extensions, warnings}` from engine status/topology plus host-provided session rows and
  extension blocks (`GenswarmsDashboard.DataSource`). The live overlay (active/idle, agent
  slot, last_activity) comes from the host's `pool_snapshot`.

  Knows ZERO transport specifics: session rows pass through with mandatory safe defaults
  (`transport: "unknown"`, `transport_ref: %{}`, `metadata: %{}` — never nil).
  """

  alias GenswarmsDashboard.Config

  @default_label "genswarms"

  # ── live wrapper (pinned by tests in the next task) ─────────────────────────
  @spec build(String.t()) :: {:ok, map()} | {:error, :not_found}
  def build(swarm_name) do
    case Genswarms.SwarmManager.status(swarm_name) do
      {:ok, status} ->
        ds = Config.get(:data_source)
        snap = ds.snapshot(swarm_name)

        data = %{
          sessions: snap.sessions,
          extensions: snap.extensions,
          pool: ds.pool_snapshot(swarm_name),
          fabricate: fabricator(ds),
          label: Config.get(:data_source_label, @default_label)
        }

        {:ok, assemble(status, topology_for(swarm_name), data, DateTime.utc_now())}

      {:error, :not_found} ->
        {:error, :not_found}
    end
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
    %{session_id: cid, transport: "unknown", transport_ref: %{}, user: nil, metadata: %{}, last_activity: nil}
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
    pool_only = for cid <- Map.keys(assigned), not MapSet.member?(durable_cids, cid), do: fabricate.(cid)

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

  # ── nodes / edges (generic swarm shape, same as the engine aggregate) ────────
  defp classify_nodes(status) do
    objects =
      Enum.map(status.objects, fn o ->
        %{name: to_string(o.name), type: "object", subtype: subtype(o[:handler])}
      end)

    agents =
      Enum.map(status.agents, fn a ->
        %{name: to_string(a.name), type: "agent", state: to_string(a.state)}
      end)

    objects ++ agents
  end

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
