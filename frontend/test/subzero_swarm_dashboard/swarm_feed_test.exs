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

  test "current/0 serves the cached last snapshot (mount seed — no empty-state flash)" do
    snap = %{"swarm" => "wingston", "summary" => %{"agents" => 2}}
    stub(SwarmClientMock, :dashboard, fn "wingston" -> {:ok, snap} end)

    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, SwarmFeed.topic())
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)
    assert_receive {:snapshot, ^snap}, 2_000

    assert SwarmFeed.current() == snap
  end

  test "current/0 is nil-safe when the feed isn't running" do
    assert SwarmFeed.current() == nil
  end

  test "broadcasts :disconnected when the swarm is unreachable" do
    stub(SwarmClientMock, :dashboard, fn _ -> {:error, :econnrefused} end)

    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, SwarmFeed.topic())
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)

    assert_receive {:disconnected, :econnrefused}, 2_000
  end

  describe "warn_silent?/5 (silent-empty guard)" do
    @snap %{"summary" => %{"agents" => 1}}

    test "warns: agents present, running past threshold, no events" do
      assert SwarmFeed.warn_silent?(@snap, nil, 20_000, 0, 15_000)
    end

    test "no warn at startup (running below threshold)" do
      refute SwarmFeed.warn_silent?(@snap, nil, 5_000, 0, 15_000)
    end

    test "no warn when WS events are recent" do
      # now - last_event_at = 100ms < threshold
      refute SwarmFeed.warn_silent?(@snap, 100, 20_000, 200, 15_000)
    end

    test "no warn when there are no agents" do
      refute SwarmFeed.warn_silent?(%{"summary" => %{"agents" => 0}}, nil, 20_000, 0, 15_000)
    end
  end
end
