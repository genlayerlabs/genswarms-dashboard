defmodule GenswarmsDashboard.AggregateTest do
  use ExUnit.Case, async: false
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
      %{
        sessions: [],
        extensions: %{},
        pool: empty_pool(),
        dashboard_title: "Wingston",
        label: "host_sql"
      },
      over
    )
  end

  test "assembles rows + live overlay: agent/state/last_activity, pool counts, extensions pass through" do
    rows = [
      %{
        session_id: "tg:1:0",
        transport: "telegram",
        transport_ref: %{chat_id: "1", thread_id: "0"},
        user: %{handle: "alberto", name: "Alberto C"},
        metadata: %{chat_type: "dm"},
        last_activity: nil
      },
      %{
        session_id: "tg:-99:0",
        transport: "telegram",
        transport_ref: %{chat_id: "-99", thread_id: "0"},
        user: nil,
        metadata: %{chat_type: "group"},
        last_activity: 1_700_000_000
      }
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

    agg =
      Aggregate.assemble(
        status(),
        topo,
        data(%{sessions: rows, pool: pool, extensions: extensions}),
        now()
      )

    assert agg.swarm == "wingston"
    assert agg.dashboard_title == "Wingston"
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

  test "a stale lease stays visible but is not active and emits a warning" do
    pool = %{
      assigned: %{"missing" => :agent_missing, "healthy" => "agent_1"},
      last_seen: %{},
      leased: 2,
      size: 8
    }

    agg = Aggregate.assemble(status(), [], data(%{pool: pool}), now())
    stale = Enum.find(agg.sessions, &(&1.session_id == "missing"))
    healthy = Enum.find(agg.sessions, &(&1.session_id == "healthy"))
    assert stale.state == "idle"
    assert stale.agent == "agent_missing"
    assert healthy.state == "active"
    assert agg.summary.pool.leased == 2
    assert Enum.any?(agg.warnings, &String.contains?(&1, "agent_missing"))

    with_host =
      Aggregate.assemble(
        status(),
        [],
        Map.put(data(%{pool: pool}), :warnings, ["Reply evidence unavailable", nil, %{}]),
        now()
      )

    assert "Reply evidence unavailable" in with_host.warnings
    assert Enum.all?(with_host.warnings, &is_binary/1)
    assert length(with_host.warnings) == 2
    assert Aggregate.assemble(status(), [], Map.put(data(), :warnings, %{}), now()).warnings == []
  end

  test "incomplete stored sessions preserve known rows but have no complete total" do
    data = data(%{sessions: [%{session_id: "known"}], sessions_available: false})
    agg = Aggregate.assemble(status(), [], data, now())
    assert agg.sessions_available == false
    assert agg.summary.sessions == nil
    assert [%{session_id: "known"}] = agg.sessions
    assert Aggregate.assemble(status(), [], %{data | sessions: []}, now()).summary.sessions == nil

    assert Aggregate.assemble(status(), [], Map.delete(data, :sessions_available), now()).summary.sessions ==
             1
  end

  test "defaults the dashboard title from the swarm name" do
    agg =
      Aggregate.assemble(
        %{status() | name: "micro-markets"},
        [],
        Map.delete(data(), :dashboard_title),
        now()
      )

    assert agg.dashboard_title == "Micro Markets"
  end

  test "a pool-only cid appears as an active session via the DEFAULT fabricated row" do
    pool = %{assigned: %{"tg:7:0" => :agent_1}, last_seen: %{}, leased: 1, size: 2048}
    agg = Aggregate.assemble(status(), [], data(%{pool: pool}), now())

    s = Enum.find(agg.sessions, &(&1.session_id == "tg:7:0"))
    assert s.state == "active" and s.agent == "agent_1"
    # generic defaults — NEVER nil for transport/transport_ref/metadata
    assert s.transport == "unknown"
    assert s.transport_ref == %{}
    assert s.metadata == %{}
    assert s.user == nil
    assert agg.summary.sessions == 1
  end

  test "a pool-only cid uses the host's fabricate override when provided" do
    pool = %{assigned: %{"tg:7:0" => :agent_1}, last_seen: %{}, leased: 1, size: 2048}

    fabricate = fn cid ->
      %{
        session_id: cid,
        transport: "telegram",
        transport_ref: %{chat_id: "7", thread_id: "0"},
        user: nil,
        metadata: %{chat_type: "dm"},
        last_activity: nil
      }
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

  test "duplicate session_ids are dropped (first row wins); row order is preserved" do
    rows = [
      %{session_id: "s1", transport: "first"},
      %{session_id: "s2"},
      %{session_id: "s1", transport: "second"}
    ]

    agg = Aggregate.assemble(status(), [], data(%{sessions: rows}), now())
    assert Enum.map(agg.sessions, & &1.session_id) == ["s1", "s2"]
    assert hd(agg.sessions).transport == "first"
    assert agg.summary.sessions == 2
  end

  test "agent backend tuple specs are projected to JSON-safe backend maps" do
    status = %{
      status()
      | agents: [
          %{
            name: :agent_1,
            state: :idle,
            backend: {:bwrap, %{memory_limit: "32M", cpu_shares: 1, tasks_max: 50}}
          }
        ]
    }

    agg = Aggregate.assemble(status, [], data(), now())

    assert [
             %{
               name: "agent_1",
               type: "agent",
               state: "idle",
               backend: %{
                 type: "bwrap",
                 opts: %{memory_limit: "32M", cpu_shares: 1, tasks_max: 50}
               }
             }
           ] = Enum.filter(agg.nodes, &(&1.type == "agent"))

    assert %{} = Jason.decode!(Jason.encode!(agg))
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

  describe "build/1 (live wrapper via stubs + fixture DataSource)" do
    setup do
      GenswarmsDashboard.Config.put(%{
        swarm: "fix",
        data_source: GenswarmsDashboard.FixtureDataSource,
        data_source_label: "fixture_sql"
      })

      Application.put_env(:genswarms_dashboard, :stub_status, %{status() | name: "fix"})

      Application.put_env(:genswarms_dashboard, :stub_topology, [
        %{from: :ingress, targets: [:agent_1]}
      ])

      on_exit(fn ->
        Application.delete_env(:genswarms_dashboard, :config)
        Application.delete_env(:genswarms_dashboard, :stub_sessions_available)
        Application.delete_env(:genswarms_dashboard, :stub_status)
        Application.delete_env(:genswarms_dashboard, :stub_topology)
      end)
    end

    test "assembles from DataSource.snapshot + pool_snapshot with the configured label" do
      {:ok, agg} = Aggregate.build("fix")
      assert agg.data_source == "fixture_sql"
      assert agg.warnings == ["Fixture source unavailable"]
      # fix:1 + fix:2 durable, fix:pool fabricated (default row — fixture has no override)
      assert agg.summary.sessions == 3
      pool_row = Enum.find(agg.sessions, &(&1.session_id == "fix:pool"))
      assert pool_row.transport == "unknown"
      assert pool_row.state == "active"
      assert pool_row.agent == "agent_2"
      assert agg.summary.pool == %{leased: 2, size: 8}
      assert %{from: "ingress", to: "agent_1"} in agg.edges
      assert agg.extensions["deliveries"].count == 1
    end

    test "host session availability crosses the live build boundary" do
      Application.put_env(:genswarms_dashboard, :stub_sessions_available, false)
      {:ok, agg} = Aggregate.build("fix")
      assert agg.sessions_available == false
      assert agg.summary.sessions == nil
      assert length(agg.sessions) == 3
    end

    test "fabricate override is used when the DataSource implements it" do
      # overrides Config for this test only; the shared setup's on_exit deletes :config after
      GenswarmsDashboard.Config.put(%{
        swarm: "fix",
        data_source: GenswarmsDashboard.FabricatingFixtureDataSource,
        data_source_label: "fixture_sql"
      })

      {:ok, agg} = Aggregate.build("fix")
      pool_row = Enum.find(agg.sessions, &(&1.session_id == "fix:pool"))
      assert pool_row.transport == "fabricated"
      assert pool_row.transport_ref == %{from: "override"}
    end

    test "a swarm name SwarmManager doesn't know returns {:error, :not_found}" do
      # stub_status is still set (for "fix") — the name-discriminating stub rejects "nope"
      assert Aggregate.build("nope") == {:error, :not_found}
    end
  end
end
