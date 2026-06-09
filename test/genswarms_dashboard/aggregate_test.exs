defmodule GenswarmsDashboard.AggregateTest do
  use ExUnit.Case, async: true
  alias GenswarmsDashboard.Aggregate

  defp status do
    %{
      name: "wingston",
      status: :running,
      started_at: ~U[2026-06-09 10:00:00Z],
      agents: [%{name: :agent_1, state: :idle}, %{name: :agent_2, state: :working}],
      objects: [
        %{name: :ingress, handler: Wingston.Objects.Ingress},
        %{name: :roster, handler: Wingston.Objects.Roster}
      ]
    }
  end

  defp now, do: ~U[2026-06-09 10:05:00Z]
  defp empty_pool, do: %{assigned: %{}, last_seen: %{}, leased: 0, size: 0}

  defp data(over \\ %{}) do
    Map.merge(
      %{sessions: [], extensions: %{}, pool: empty_pool(), label: "host_sql"},
      over
    )
  end

  test "assembles rows + live overlay: agent/state/last_activity, pool counts, extensions pass through" do
    rows = [
      %{session_id: "tg:1:0", transport: "telegram", transport_ref: %{chat_id: "1", thread_id: "0"},
        user: %{handle: "alberto", name: "Alberto C"}, metadata: %{chat_type: "dm"}, last_activity: nil},
      %{session_id: "tg:-99:0", transport: "telegram", transport_ref: %{chat_id: "-99", thread_id: "0"},
        user: nil, metadata: %{chat_type: "group"}, last_activity: 1_700_000_000}
    ]

    pool = %{
      assigned: %{"tg:1:0" => :agent_1},
      last_seen: %{"tg:1:0" => ~U[2026-06-09 10:04:30Z]},
      leased: 1,
      size: 2048
    }

    extensions = %{
      "consumers" => %{count: 2, items: []},
      "deliveries" => %{count: 1, items: [%{session_id: "tg:1:0", status: "sent", at: "x"}]}
    }

    topo = [%{from: :ingress, targets: [:roster, :agent_1]}]
    agg = Aggregate.assemble(status(), topo, data(%{sessions: rows, pool: pool, extensions: extensions}), now())

    assert agg.swarm == "wingston"
    assert agg.data_source == "host_sql"
    assert agg.uptime_s == 300
    assert agg.summary.agents == 2 and agg.summary.objects == 2
    assert agg.summary.sessions == 2
    assert agg.summary.pool == %{leased: 1, size: 2048}

    names = MapSet.new(agg.nodes, & &1.name)
    assert MapSet.equal?(names, MapSet.new(~w(ingress roster agent_1 agent_2)))
    assert %{from: "ingress", to: "agent_1"} in agg.edges

    dm = Enum.find(agg.sessions, &(&1.session_id == "tg:1:0"))
    assert dm.state == "active"
    assert dm.agent == "agent_1"
    assert dm.user == %{handle: "alberto", name: "Alberto C"}
    assert dm.metadata.chat_type == "dm"
    assert dm.transport_ref == %{chat_id: "1", thread_id: "0"}
    assert dm.last_activity == ~U[2026-06-09 10:04:30Z]

    grp = Enum.find(agg.sessions, &(&1.session_id == "tg:-99:0"))
    assert grp.state == "idle"
    assert grp.agent == nil
    # not in the live pool ⇒ falls back to the row's durable last_activity
    assert grp.last_activity == 1_700_000_000

    assert agg.extensions == extensions
  end

  test "a pool-only cid appears as an active session via the DEFAULT fabricated row" do
    pool = %{assigned: %{"tg:7:0" => :agent_3}, last_seen: %{}, leased: 1, size: 2048}
    agg = Aggregate.assemble(status(), [], data(%{pool: pool}), now())

    s = Enum.find(agg.sessions, &(&1.session_id == "tg:7:0"))
    assert s.state == "active" and s.agent == "agent_3"
    # generic defaults — NEVER nil for transport/transport_ref/metadata
    assert s.transport == "unknown"
    assert s.transport_ref == %{}
    assert s.metadata == %{}
    assert s.user == nil
    assert agg.summary.sessions == 1
  end

  test "a pool-only cid uses the host's fabricate override when provided" do
    pool = %{assigned: %{"tg:7:0" => :agent_3}, last_seen: %{}, leased: 1, size: 2048}
    fabricate = fn cid ->
      %{session_id: cid, transport: "telegram", transport_ref: %{chat_id: "7", thread_id: "0"},
        user: nil, metadata: %{chat_type: "dm"}, last_activity: nil}
    end

    agg = Aggregate.assemble(status(), [], data(%{pool: pool, fabricate: fabricate}), now())
    s = Enum.find(agg.sessions, &(&1.session_id == "tg:7:0"))
    assert s.transport == "telegram"
    assert s.transport_ref == %{chat_id: "7", thread_id: "0"}
    assert s.state == "active"
  end

  test "sparse rows get every mandatory default filled (nil values included)" do
    rows = [%{session_id: "s1", transport: nil, transport_ref: nil, metadata: nil}]
    agg = Aggregate.assemble(status(), [], data(%{sessions: rows}), now())
    [s] = agg.sessions
    assert s.transport == "unknown"
    assert s.transport_ref == %{}
    assert s.metadata == %{}
    assert s.user == nil
    assert s.last_activity == nil
    assert s.state == "idle" and s.agent == nil
  end

  test "empty everything yields a well-formed, empty aggregate with the default label" do
    agg = Aggregate.assemble(status(), [], Map.delete(data(), :label), now())
    assert agg.data_source == "genswarms"
    assert agg.summary.sessions == 0
    assert agg.summary.pool == %{leased: 0, size: 0}
    assert agg.sessions == []
    assert agg.extensions == %{}
    assert agg.warnings == []
    assert length(agg.nodes) == 4
  end
end
