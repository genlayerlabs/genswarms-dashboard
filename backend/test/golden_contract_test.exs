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
      Application.delete_env(:genswarms_dashboard, :stub_last_feed_query)
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
    assert call.(:get, "/api/swarms/fix/events/feed").status == 200
    assert call.(:options, "/api/swarms/fix/dashboard").status == 204
    assert call.(:get, "/").status == 404
    assert call.(:get, "/api/swarms/fix/other").status == 404
  end

  test "events feed: exact envelope, both source labels, unknown event fields relay verbatim" do
    call = fn path ->
      GenswarmsDashboard.Plug.call(conn(:get, path), GenswarmsDashboard.Plug.init([]))
    end

    # no events_source configured (the setup map) ⇒ the exact unavailable envelope, still 200
    conn = call.("/api/swarms/fix/events/feed")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"events" => [], "seq" => 0, "source" => "unavailable"}

    Config.put(%{
      swarm: "fix",
      data_source: GenswarmsDashboard.FixtureDataSource,
      data_source_label: "fixture_sql",
      token: nil,
      events_source: GenswarmsDashboard.FixtureEventsSource
    })

    body = call.("/api/swarms/fix/events/feed").resp_body |> Jason.decode!()
    assert Map.keys(body) |> Enum.sort() == ~w(events seq source)
    assert body["source"] == "feed"
    # seq is the feed's current cursor, never an echo of since (pinned in the EventsSource @doc)
    assert body["seq"] == 2
    # the backend never interprets a kind: unknown kinds and fields pass through verbatim
    assert Enum.at(body["events"], 1) == %{
             "seq" => 2,
             "ts" => 1_718_000_001.5,
             "kind" => "totally_unknown",
             "mystery" => %{"nested" => true},
             "extra" => "verbatim"
           }
  end

  test "WS: the exact pinned event-name list" do
    assert GenswarmsDashboard.Channel.relayed_events() ==
             ~w(heartbeat agent_status message_routed message_broadcast agent_added
                agent_removed topology_changed agent_output swarm_started swarm_stopped)
  end
end
