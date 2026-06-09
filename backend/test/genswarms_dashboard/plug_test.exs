defmodule GenswarmsDashboard.PlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias GenswarmsDashboard.Config

  @opts GenswarmsDashboard.Plug.init([])

  defp put_config(over \\ %{}) do
    Config.put(
      Map.merge(
        %{swarm: "fix", data_source: GenswarmsDashboard.FixtureDataSource,
          data_source_label: "fixture_sql", token: nil},
        over
      )
    )
  end

  setup do
    put_config()

    on_exit(fn ->
      Application.delete_env(:genswarms_dashboard, :config)
      for k <- [:stub_status, :stub_topology, :stub_events, :stub_logs, :stub_last_events_query],
          do: Application.delete_env(:genswarms_dashboard, k)
    end)

    :ok
  end

  defp call(conn), do: GenswarmsDashboard.Plug.call(conn, @opts)

  # ── auth gate (migrated 1:1 from wingston's plug test) ──────────────────────
  test "no token configured ⇒ no auth required (locality is the gate); unknown route is 404" do
    conn = call(conn(:get, "/nope"))
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  test "token configured + NO bearer ⇒ 401" do
    put_config(%{token: "s3cret"})
    conn = call(conn(:get, "/api/swarms/fix/dashboard"))
    assert conn.status == 401
    assert conn.halted
  end

  test "token configured + WRONG bearer ⇒ 401" do
    put_config(%{token: "s3cret"})
    conn = call(conn(:get, "/api/swarms/fix/dashboard") |> put_req_header("authorization", "Bearer nope"))
    assert conn.status == 401
  end

  test "token configured + CORRECT bearer ⇒ passes auth (unknown route → 404, not 401)" do
    put_config(%{token: "s3cret"})
    conn = call(conn(:get, "/nope") |> put_req_header("authorization", "Bearer s3cret"))
    assert conn.status == 404
    refute conn.halted
  end

  test "token configured + correct ?token= query param ⇒ passes auth (browser path)" do
    put_config(%{token: "s3cret"})
    conn = call(conn(:get, "/nope?token=s3cret"))
    assert conn.status == 404
    refute conn.halted
  end

  test "token configured + wrong ?token= ⇒ 401" do
    put_config(%{token: "s3cret"})
    conn = call(conn(:get, "/nope?token=nope"))
    assert conn.status == 401
  end

  test "CORS headers are present on responses" do
    conn = call(conn(:get, "/nope"))
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  # ── routes (new — pinned against fixture + stubs) ───────────────────────────
  test "GET /dashboard returns the aggregate; unknown swarm is 404 swarm_not_found" do
    Application.put_env(:genswarms_dashboard, :stub_status, %{
      name: "fix", status: :running, started_at: ~U[2026-06-09 10:00:00Z], agents: [], objects: []
    })

    conn = call(conn(:get, "/api/swarms/fix/dashboard"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["swarm"] == "fix"
    assert body["data_source"] == "fixture_sql"

    Application.delete_env(:genswarms_dashboard, :stub_status)
    conn = call(conn(:get, "/api/swarms/fix/dashboard"))
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "swarm_not_found"}
  end

  test "GET /history serves the durable transcript; unknown session ⇒ source unavailable" do
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:1/history"))
    assert conn.status == 200
    assert %{"session_id" => "fix:1", "turns" => [_], "source" => "store"} = Jason.decode!(conn.resp_body)

    conn = call(conn(:get, "/api/swarms/fix/sessions/ghost/history"))
    assert %{"turns" => [], "source" => "unavailable"} = Jason.decode!(conn.resp_body)
  end

  test "GET /logs resolves the LIVE slot via pool_snapshot and renames session_id→log_file" do
    Application.put_env(:genswarms_dashboard, :stub_logs, fn :agent_1 ->
      [%{"session_id" => "agent_1.log", "line" => "hello"}]
    end)

    # fix:1 is leased to :agent_1 in the fixture pool_snapshot
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:1/logs"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["source"] == "slot"
    assert [%{"log_file" => "agent_1.log", "line" => "hello"}] = body["logs"]

    # fix:2 is durable but NOT leased ⇒ unavailable (no slot bleed)
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:2/logs"))
    assert %{"logs" => [], "source" => "unavailable"} = Jason.decode!(conn.resp_body)
  end

  test "GET /events queries LogStore with normalized opts and formats events" do
    Application.put_env(:genswarms_dashboard, :stub_events, [
      %{id: 1, timestamp: ~U[2026-06-09 10:00:00Z], level: :info, category: :routing,
        swarm: "fix", agent: nil, event_type: "message_routed", message: "m", metadata: %{}}
    ])

    conn = call(conn(:get, "/api/swarms/fix/events?limit=5&minutes=10&category=router&level=bogus_level"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["count"] == 1 and body["swarm"] == "fix"
    assert [%{"timestamp" => "2026-06-09T10:00:00Z", "event_type" => "message_routed"}] = body["events"]

    opts = Application.get_env(:genswarms_dashboard, :stub_last_events_query)
    assert opts[:limit] == 5
    assert opts[:minutes] == 10
    # "router" is normalized to the stored :routing category; an un-interned level is DROPPED
    assert opts[:category] == :routing
    refute Keyword.has_key?(opts, :level)
  end

  test "attacker-sized integer query params are capped at 10_000" do
    conn = call(conn(:get, "/api/swarms/fix/events?limit=99999999999999999"))
    assert conn.status == 200
    opts = Application.get_env(:genswarms_dashboard, :stub_last_events_query)
    assert opts[:limit] == 10_000
  end

  test "OPTIONS preflight is 204" do
    conn = call(conn(:options, "/api/swarms/fix/dashboard"))
    assert conn.status == 204
  end
end
