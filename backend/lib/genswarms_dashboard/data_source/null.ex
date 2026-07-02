defmodule GenswarmsDashboard.DataSource.Null do
  @moduledoc """
  Engine-only default `DataSource`: no durable store, no session pool.

  Makes the dashboard bootable with ZERO host code — overview, topology, events
  and logs render from the engine modules alone; the sessions list is empty and
  transcripts answer `:unavailable`. A host with a durable store replaces this
  with its own adapter (see the `DataSource` moduledoc).
  """
  @behaviour GenswarmsDashboard.DataSource

  @impl true
  def snapshot(_swarm), do: %{sessions: [], extensions: %{}}

  @impl true
  def session_history(_cid, _max_turns), do: :unavailable

  @impl true
  def pool_snapshot(_swarm), do: %{assigned: %{}, last_seen: %{}, leased: 0, size: 0}
end
