defmodule SubzeroSwarmDashboard.SwarmClient.HttpTest do
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboard.SwarmClient.Http

  # The Req.Test stub intercepts by request_path regardless of host, so the default
  # swarm_api_url is fine.

  test "dashboard/1 GETs the aggregate and returns the body on 200" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      assert conn.request_path == "/api/swarms/wingston/dashboard"
      Req.Test.json(conn, %{"swarm" => "wingston"})
    end)

    assert {:ok, %{"swarm" => "wingston"}} = Http.dashboard("wingston")
  end

  test "non-200 maps to {:error, {:http, status}}" do
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Plug.Conn.send_resp(conn, 404, "nope")
    end)

    assert {:error, {:http, 404}} = Http.dashboard("x")
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
end
