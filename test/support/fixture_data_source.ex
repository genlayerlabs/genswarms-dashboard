defmodule GenswarmsDashboard.FixtureDataSource do
  @moduledoc "Fixture DataSource for library tests. Does NOT implement fabricate_session/1 (default path)."
  @behaviour GenswarmsDashboard.DataSource

  @impl true
  def snapshot(_swarm) do
    %{
      sessions: [
        %{
          session_id: "fix:1",
          transport: "fixture",
          transport_ref: %{ref: "one"},
          user: %{name: "Fia"},
          metadata: %{kind: "x"},
          last_activity: ~U[2026-06-09 09:00:00Z]
        },
        # sparse row: only session_id — the aggregate must fill every default
        %{session_id: "fix:2"}
      ],
      extensions: %{
        "consumers" => %{count: 2, items: [%{session_id: "fix:1"}]},
        "deliveries" => %{count: 1, items: [%{session_id: "fix:1", status: "sent", at: "2026-06-09T09:00:00Z"}]}
      }
    }
  end

  @impl true
  def session_history("fix:1", _max), do: {:ok, [%{role: "user", content: "hi"}]}
  def session_history(_cid, _max), do: :unavailable

  @impl true
  def pool_snapshot(_swarm) do
    %{
      assigned: %{"fix:1" => :agent_1, "fix:pool" => :agent_2},
      last_seen: %{"fix:1" => ~U[2026-06-09 10:04:30Z]},
      leased: 2,
      size: 8
    }
  end
end

defmodule GenswarmsDashboard.FabricatingFixtureDataSource do
  @moduledoc "Same fixture, but overrides fabricate_session/1 — exercises the override path."
  @behaviour GenswarmsDashboard.DataSource

  @impl true
  defdelegate snapshot(swarm), to: GenswarmsDashboard.FixtureDataSource
  @impl true
  defdelegate session_history(cid, max), to: GenswarmsDashboard.FixtureDataSource
  @impl true
  defdelegate pool_snapshot(swarm), to: GenswarmsDashboard.FixtureDataSource

  @impl true
  def fabricate_session(cid) do
    %{session_id: cid, transport: "fabricated", transport_ref: %{from: "override"},
      user: nil, metadata: %{}, last_activity: nil}
  end
end
