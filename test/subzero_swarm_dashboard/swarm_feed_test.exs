defmodule SubzeroSwarmDashboard.SwarmFeedTest do
  use ExUnit.Case, async: false
  import Mox

  alias SubzeroSwarmDashboard.{SwarmFeed, SwarmClientMock}

  setup :set_mox_global

  test "polls and broadcasts a snapshot on the feed topic" do
    snap = %{"swarm" => "wingston", "summary" => %{"agents" => 0}}
    stub(SwarmClientMock, :dashboard, fn "wingston" -> {:ok, snap} end)

    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, SwarmFeed.topic())
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)

    assert_receive {:snapshot, ^snap}, 2_000
  end

  test "broadcasts :disconnected when the swarm is unreachable" do
    stub(SwarmClientMock, :dashboard, fn _ -> {:error, :econnrefused} end)

    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, SwarmFeed.topic())
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)

    assert_receive {:disconnected, :econnrefused}, 2_000
  end
end
