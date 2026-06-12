defmodule SubzeroSwarmDashboard.SwarmClientTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!

  alias SubzeroSwarmDashboard.{SwarmClient, SwarmClientMock}

  test "dashboard/1 delegates to the configured impl" do
    expect(SwarmClientMock, :dashboard, fn "wingston" -> {:ok, %{"swarm" => "wingston"}} end)
    assert {:ok, %{"swarm" => "wingston"}} = SwarmClient.dashboard("wingston")
  end

  test "session_history/2 delegates to the configured impl" do
    expect(SwarmClientMock, :session_history, fn "wingston", "tg:1:0" ->
      {:ok, %{"turns" => [], "source" => "unavailable"}}
    end)

    assert {:ok, %{"source" => "unavailable"}} = SwarmClient.session_history("wingston", "tg:1:0")
  end

  test "events_feed/3 delegates to the configured impl" do
    expect(SwarmClientMock, :events_feed, fn "wingston", 42, 500 ->
      {:ok, %{"events" => [], "seq" => 42, "source" => "feed"}}
    end)

    assert {:ok, %{"seq" => 42}} = SwarmClient.events_feed("wingston", 42, 500)
  end
end
