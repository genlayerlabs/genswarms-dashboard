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
end
