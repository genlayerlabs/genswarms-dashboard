defmodule GoldenContractTest do
  @moduledoc """
  THE WIRE CONTRACT. The frontend (subzero-swarm-dashboard) reads these shapes as-is.
  A failure here means a frontend-visible change — do not "fix" this test without
  checking the frontend first.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias GenswarmsDashboard.{Aggregate, Config}

  setup do
    Config.put(%{
      swarm: "fix",
      data_source: GenswarmsDashboard.FixtureDataSource,
      data_source_label: "fixture_sql",
      token: nil
    })

    Application.put_env(:genswarms_dashboard, :stub_status, %{
      name: "fix", status: :running, started_at: ~U[2026-06-09 10:00:00Z], agents: [], objects: []
    })

    on_exit(fn ->
      Application.delete_env(:genswarms_dashboard, :config)
      Application.delete_env(:genswarms_dashboard, :stub_status)
    end)
  end

  test "envelope: exact top-level, summary, pool, and session-row key sets; JSON-encodable" do
    {:ok, agg} = Aggregate.build("fix")

    assert Map.keys(agg) |> Enum.sort() ==
             ~w(data_source edges extensions generated_at nodes sessions status summary swarm uptime_s warnings)a

    assert Map.keys(agg.summary) |> Enum.sort() == ~w(agents objects pool sessions)a
    assert Map.keys(agg.summary.pool) |> Enum.sort() == ~w(leased size)a

    for session <- agg.sessions do
      assert Map.keys(session) |> Enum.sort() ==
               ~w(agent last_activity metadata session_id state transport transport_ref user)a

      # the never-nil invariants
      assert is_binary(session.transport)
      assert is_map(session.transport_ref)
      assert is_map(session.metadata)
      assert session.state in ["active", "idle"]
    end

    assert %{} = Jason.decode!(Jason.encode!(agg))
  end

  test "routes: the exact pinned route set answers; everything else is 404" do
    call = fn method, path ->
      GenswarmsDashboard.Plug.call(conn(method, path), GenswarmsDashboard.Plug.init([]))
    end

    assert call.(:get, "/api/swarms/fix/dashboard").status == 200
    assert call.(:get, "/api/swarms/fix/sessions/fix:1/history").status == 200
    assert call.(:get, "/api/swarms/fix/sessions/fix:1/logs").status == 200
    assert call.(:get, "/api/swarms/fix/sessions/fix:1/skills").status == 200
    assert call.(:get, "/api/swarms/fix/events").status == 200
    assert call.(:options, "/api/swarms/fix/dashboard").status == 204
    assert call.(:get, "/").status == 404
    assert call.(:get, "/api/swarms/fix/other").status == 404
  end

  test "WS: the exact pinned event-name list" do
    assert GenswarmsDashboard.Channel.relayed_events() ==
             ~w(heartbeat agent_status message_routed message_broadcast agent_added
                agent_removed topology_changed agent_output swarm_started swarm_stopped)
  end
end
