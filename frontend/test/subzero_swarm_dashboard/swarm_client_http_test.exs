defmodule SubzeroSwarmDashboard.SwarmClient.HttpTest do
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboard.SwarmClient.Http

  # The Req.Test stub intercepts by request_path regardless of host, so the default
  # swarm_api_url is fine.

  test "swarms/0 unwraps the shared fleet catalog" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms"
      Req.Test.json(conn, %{"swarms" => [%{"name" => "strategivm"}], "count" => 1})
    end)

    assert {:ok, [%{"name" => "strategivm"}]} = Http.swarms()
  end

  test "dashboard/1 GETs the aggregate and returns the body on 200" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms/wingston/dashboard"
      Req.Test.json(conn, %{"swarm" => "wingston"})
    end)

    assert {:ok, %{"swarm" => "wingston"}} = Http.dashboard("wingston")
  end

  test "a projected session label does not retain the discarded HTTP response buffer" do
    label = String.duplicate("synthetic name ", 10)

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Req.Test.json(conn, %{
        "sessions" => [%{"session_id" => "test:1:0", "user" => %{"name" => label}}],
        "extensions" => %{"unused" => String.duplicate("x", 1_000_000)}
      })
    end)

    {:ok, source} = Http.dashboard("wingston")
    page = SubzeroSwarmDashboardWeb.SnapshotView.project(source, %{})
    retained = hd(page["sessions"])["user"]["name"]

    assert retained == label
    refute Map.has_key?(page["extensions"], "unused")
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "non-200 maps to {:error, {:http, status}}" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Plug.Conn.send_resp(conn, 404, "nope")
    end)

    assert {:error, {:http, 404}} = Http.dashboard("x")
  end

  test "scheduled polls return a transient failure without retrying inside the call" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      attempts = Process.get(:swarm_attempts, 0)
      Process.put(:swarm_attempts, attempts + 1)
      Plug.Conn.send_resp(conn, if(attempts == 0, do: 503, else: 200), "{}")
    end)

    assert {:error, {:http, 503}} = Http.dashboard("wingston")
    assert Process.get(:swarm_attempts) == 1
  end

  test "session_history hits the history route" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms/wingston/sessions/tg:1:0/history"
      Req.Test.json(conn, %{"turns" => [], "source" => "unavailable"})
    end)

    assert {:ok, %{"source" => "unavailable"}} = Http.session_history("wingston", "tg:1:0")
  end

  test "events unwraps the {\"events\": [...]} envelope" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms/wingston/events"
      Req.Test.json(conn, %{"events" => [%{"message" => "hi"}]})
    end)

    assert {:ok, [%{"message" => "hi"}]} = Http.events("wingston", %{level: "info"})
  end

  test "events_feed hits the feed route with cursor params and passes the envelope through" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms/wingston/events/feed"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.params == %{"since" => "42", "limit" => "500"}

      Req.Test.json(conn, %{
        "events" => [%{"kind" => "request_open", "seq" => 43, "novel_field" => true}],
        "seq" => 43,
        "source" => "feed"
      })
    end)

    assert {:ok, %{"events" => [%{"novel_field" => true}], "seq" => 43, "source" => "feed"}} =
             Http.events_feed("wingston", 42, 500)
  end
end
