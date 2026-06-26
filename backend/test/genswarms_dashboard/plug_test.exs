defmodule GenswarmsDashboard.PlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias GenswarmsDashboard.Config

  @opts GenswarmsDashboard.Plug.init([])

  defp put_config(over \\ %{}) do
    Config.put(
      Map.merge(
        %{
          swarm: "fix",
          data_source: GenswarmsDashboard.FixtureDataSource,
          data_source_label: "fixture_sql",
          token: nil
        },
        over
      )
    )
  end

  setup do
    put_config()

    on_exit(fn ->
      Application.delete_env(:genswarms_dashboard, :config)

      for k <- [
            :stub_status,
            :stub_topology,
            :stub_events,
            :stub_logs,
            :stub_skills,
            :stub_last_events_query,
            :stub_last_feed_query
          ],
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

    conn =
      call(
        conn(:get, "/api/swarms/fix/dashboard")
        |> put_req_header("authorization", "Bearer nope")
      )

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
      name: "fix",
      status: :running,
      started_at: ~U[2026-06-09 10:00:00Z],
      agents: [],
      objects: []
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

  test "GET /dashboard JSON-encodes bwrap backend resource caps from live agent status" do
    Application.put_env(:genswarms_dashboard, :stub_status, %{
      name: "fix",
      status: :running,
      started_at: ~U[2026-06-09 10:00:00Z],
      agents: [
        %{
          name: :agent_1,
          state: :idle,
          backend: {:bwrap, %{memory_limit: "32M", cpu_shares: 1, tasks_max: 50}}
        }
      ],
      objects: []
    })

    conn = call(conn(:get, "/api/swarms/fix/dashboard"))

    assert conn.status == 200

    assert %{
             "nodes" => [
               %{
                 "name" => "agent_1",
                 "backend" => %{
                   "type" => "bwrap",
                   "opts" => %{"memory_limit" => "32M", "cpu_shares" => 1, "tasks_max" => 50}
                 }
               }
             ]
           } = Jason.decode!(conn.resp_body)
  end

  test "GET /history serves the durable transcript; unknown session ⇒ source unavailable" do
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:1/history"))
    assert conn.status == 200

    assert %{"session_id" => "fix:1", "turns" => [_], "source" => "store"} =
             Jason.decode!(conn.resp_body)

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

  test "GET /skills serves the leased slot's skills dir (the prompt source), host path stripped" do
    Application.put_env(:genswarms_dashboard, :stub_skills, fn :agent_1 ->
      [%{name: "browse.md", content: "# Browse\nRender pages.", path: "/host/skills/browse.md"}]
    end)

    # fix:1 is leased to :agent_1 in the fixture pool_snapshot
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:1/skills"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["source"] == "slot"

    assert [%{"name" => "browse.md", "content" => "# Browse\nRender pages."} = skill] =
             body["skills"]

    # the engine also returns the host filesystem :path — must never reach the wire
    refute Map.has_key?(skill, "path")
  end

  test "GET /skills falls back to another live agent when the session isn't leased (source: pool)" do
    # Sessions are mostly inspected AFTER the slot was recycled — unlike /logs,
    # skills must not go dark with the lease.
    Application.put_env(:genswarms_dashboard, :stub_skills, fn slot ->
      [%{name: "browse.md", content: "from #{slot}", path: "/host/skills/browse.md"}]
    end)

    # fix:2 is durable but NOT leased; the fixture pool has other live slots
    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:2/skills"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["source"] == "pool"
    assert [%{"name" => "browse.md", "content" => "from " <> _}] = body["skills"]
  end

  test "GET /skills is unavailable only when there is no live agent at all" do
    # no data source (no pool to fall back to) and no swarm status (stub unset ⇒ not_found)
    put_config(%{data_source: nil})

    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:1/skills"))
    assert %{"skills" => [], "source" => "unavailable"} = Jason.decode!(conn.resp_body)
  end

  test "GET /events queries LogStore with normalized opts and formats events" do
    Application.put_env(:genswarms_dashboard, :stub_events, [
      %{
        id: 1,
        timestamp: ~U[2026-06-09 10:00:00Z],
        level: :info,
        category: :routing,
        swarm: "fix",
        agent: nil,
        event_type: "message_routed",
        message: "m",
        metadata: %{
          reason: "ok",
          status: :sent,
          conversation_id: "tg:1:0",
          market_address: "0x1111111111111111111111111111111111111111",
          oracle_address: "0x2222222222222222222222222222222222222222",
          api_key: "sk-secret",
          workspace: "/Users/albert/szc-workspace/tg:1:0",
          url: "https://example.invalid/private",
          amount: 123
        }
      }
    ])

    conn =
      call(
        conn(:get, "/api/swarms/fix/events?limit=5&minutes=10&category=router&level=bogus_level")
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["count"] == 1 and body["swarm"] == "fix"

    assert [
             %{
               "timestamp" => "2026-06-09T10:00:00Z",
               "event_type" => "message_routed",
               "metadata" => %{"reason" => "ok", "status" => "sent"}
             } = event
           ] = body["events"]

    refute inspect(event) =~ "tg:1:0"
    refute inspect(event) =~ "0x111111"
    refute inspect(event) =~ "0x222222"
    refute inspect(event) =~ "sk-secret"
    refute inspect(event) =~ "/Users/albert"
    refute inspect(event) =~ "example.invalid"
    refute inspect(event) =~ "123"

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

  # ── events feed (host EventsSource) ─────────────────────────────────────────
  test "GET /events/feed relays the EventsSource batch with source: feed" do
    put_config(%{events_source: GenswarmsDashboard.FixtureEventsSource})

    conn = call(conn(:get, "/api/swarms/fix/events/feed?since=1&limit=50"))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["source"] == "feed"
    assert body["seq"] == 2
    assert [%{"seq" => 2, "kind" => "totally_unknown"}] = body["events"]
    # the source saw the parsed cursor args
    assert Application.get_env(:genswarms_dashboard, :stub_last_feed_query) == {1, 50}

    # pinned cursor semantics on the wire: an inflated since comes back with the
    # feed's own cursor, never an echo — the consumer can see the regression
    conn = call(conn(:get, "/api/swarms/fix/events/feed?since=99"))
    assert %{"events" => [], "seq" => 2, "source" => "feed"} = Jason.decode!(conn.resp_body)
  end

  test "GET /events/feed defaults since=0 limit=500; limit is capped at 10_000" do
    put_config(%{events_source: GenswarmsDashboard.FixtureEventsSource})

    call(conn(:get, "/api/swarms/fix/events/feed"))
    assert Application.get_env(:genswarms_dashboard, :stub_last_feed_query) == {0, 500}

    call(conn(:get, "/api/swarms/fix/events/feed?limit=99999999999999999"))
    assert Application.get_env(:genswarms_dashboard, :stub_last_feed_query) == {0, 10_000}
  end

  test "GET /events/feed since is an uncapped cursor — never clamped to @int_cap" do
    put_config(%{events_source: GenswarmsDashboard.FixtureEventsSource})

    # lifetime seqs legitimately exceed any size cap; a clamped cursor would
    # re-deliver every event above the cap forever
    call(conn(:get, "/api/swarms/fix/events/feed?since=2000000"))
    assert Application.get_env(:genswarms_dashboard, :stub_last_feed_query) == {2_000_000, 500}
  end

  test "GET /events/feed without an events_source configured ⇒ source unavailable, still 200" do
    conn = call(conn(:get, "/api/swarms/fix/events/feed"))
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "events" => [],
             "seq" => 0,
             "source" => "unavailable"
           }
  end

  test "GET /events/feed degrades to unavailable when the source returns :unavailable, raises, or exits" do
    for source <- [
          GenswarmsDashboard.UnavailableEventsSource,
          GenswarmsDashboard.RaisingEventsSource,
          GenswarmsDashboard.ExitingEventsSource
        ] do
      put_config(%{events_source: source})
      conn = call(conn(:get, "/api/swarms/fix/events/feed"))
      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "events" => [],
               "seq" => 0,
               "source" => "unavailable"
             }
    end
  end

  test "GET /events/feed sits behind the auth plug like every route" do
    put_config(%{token: "s3cret", events_source: GenswarmsDashboard.FixtureEventsSource})

    conn = call(conn(:get, "/api/swarms/fix/events/feed"))
    assert conn.status == 401
    assert conn.halted

    conn =
      call(
        conn(:get, "/api/swarms/fix/events/feed")
        |> put_req_header("authorization", "Bearer s3cret")
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["source"] == "feed"
  end

  test "OPTIONS preflight is 204" do
    conn = call(conn(:options, "/api/swarms/fix/dashboard"))
    assert conn.status == 204
  end

  # B5: SwarmManager.status is a 5s GenServer.call; under docker latency it can
  # time out (exit). The skills route falls through to it (via any_live_agent) and
  # MUST degrade to source:"unavailable", not crash the read API to a 500.
  test "skills route survives a SwarmManager.status timeout (exit), not a 500" do
    # no data_source ⇒ live_slot + pool_agent are nil, so the route reaches status.
    put_config(%{data_source: nil})

    Application.put_env(:genswarms_dashboard, :stub_status, fn _ ->
      exit({:timeout, {GenServer, :call, [Genswarms.SwarmManager, :status, 5000]}})
    end)

    conn = call(conn(:get, "/api/swarms/fix/sessions/fix:99/skills"))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["source"] == "unavailable"
  end

  # The /dashboard aggregate route must DEGRADE (503), not crash to a 500, when
  # SwarmManager.status times out (it's blocked behind a docker op).
  test "dashboard route returns 503 when SwarmManager.status times out, not a 500" do
    Application.put_env(:genswarms_dashboard, :stub_status, fn _ ->
      exit({:timeout, {GenServer, :call, [Genswarms.SwarmManager, :status, 5000]}})
    end)

    conn = call(conn(:get, "/api/swarms/fix/dashboard"))

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "swarm_status_unavailable"}
  end

  # The JSON error view (wired via render_errors) renders a clean body — so a 500 that
  # does reach the endpoint doesn't fail again on a missing template.
  test "ErrorJSON renders a clean JSON error body" do
    assert GenswarmsDashboard.ErrorJSON.render("500.json", %{}) == %{error: "Internal Server Error"}
    assert GenswarmsDashboard.ErrorJSON.render("404.json", %{}) == %{error: "Not Found"}
  end
end
