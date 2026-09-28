defmodule SubzeroSwarmDashboard.SwarmFeedTest do
  use ExUnit.Case, async: false
  import Mox

  alias SubzeroSwarmDashboard.{SwarmFeed, SwarmClientMock}

  setup :set_mox_global

  test "polls and broadcasts a snapshot on the feed topic" do
    snap = %{"swarm" => "wingston", "summary" => %{"agents" => 0}}
    stub(SwarmClientMock, :dashboard, fn "wingston" -> {:ok, snap} end)

    SwarmFeed.subscribe()
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)

    assert_receive {:snapshot_ready, revision}, 2_000
    assert is_integer(revision)
  end

  test "current/0 serves the cached last snapshot (mount seed — no empty-state flash)" do
    snap = %{"swarm" => "wingston", "summary" => %{"agents" => 2}}
    stub(SwarmClientMock, :dashboard, fn "wingston" -> {:ok, snap} end)

    SwarmFeed.subscribe()
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)
    assert_receive {:snapshot_ready, revision}, 2_000
    assert is_integer(revision)

    assert SwarmFeed.current() == snap
  end

  test "current/0 is nil-safe when the feed isn't running" do
    assert SwarmFeed.current() == nil
  end

  test "broadcasts :disconnected when the swarm is unreachable" do
    stub(SwarmClientMock, :dashboard, fn _ -> {:error, :econnrefused} end)

    SwarmFeed.subscribe()
    start_supervised!(SubzeroSwarmDashboard.SwarmFeed)

    assert_receive {:disconnected, _, :econnrefused}, 2_000
  end

  test "idle feed skips snapshots, resumes for viewers, and stops when the last viewer exits" do
    test = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(test, :dashboard_read)
      {:ok, %{"summary" => %{"agents" => 0}}}
    end)

    Application.put_env(:subzero_swarm_dashboard, :poll_interval_ms, 20)
    on_exit(fn -> Application.delete_env(:subzero_swarm_dashboard, :poll_interval_ms) end)
    feed = start_supervised!(SwarmFeed)
    # Internal subscribers (EventsFeed, silent-feed guard) do not create demand.
    Phoenix.PubSub.subscribe(SubzeroSwarmDashboard.PubSub, SwarmFeed.topic())
    refute_receive :dashboard_read, 100

    viewer =
      start_supervised!(
        {Task,
         fn ->
           SwarmFeed.subscribe()

           receive do
             :stop -> :ok
           end
         end}
      )

    assert_receive :dashboard_read
    assert_receive {:snapshot_ready, _}
    monitor = Process.monitor(viewer)
    send(viewer, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^viewer, :normal}
    # Drain any poll already in flight before the viewer exited.
    _ = :sys.get_state(feed)

    receive do
      :dashboard_read -> :ok
    after
      0 -> :ok
    end

    refute_receive :dashboard_read, 100

    SwarmFeed.subscribe()
    assert_receive :dashboard_read
  end

  test "repeat subscriptions do not multiply polls and demand survives a feed restart" do
    test = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(test, :dashboard_read)
      {:ok, %{"summary" => %{"agents" => 0}}}
    end)

    Application.put_env(:subzero_swarm_dashboard, :poll_interval_ms, 1_000)
    on_exit(fn -> Application.delete_env(:subzero_swarm_dashboard, :poll_interval_ms) end)
    start_supervised!(SwarmFeed)
    SwarmFeed.subscribe()
    assert_receive :dashboard_read
    SwarmFeed.subscribe()
    SwarmFeed.subscribe()
    refute_receive :dashboard_read, 100
    stop_supervised(SwarmFeed)
    start_supervised!(SwarmFeed)
    assert_receive :dashboard_read
    refute_receive :dashboard_read, 100
  end

  test "event collection continues without snapshot viewers" do
    test = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(test, :dashboard_read)
      {:ok, %{}}
    end)

    stub(SwarmClientMock, :events_feed, fn _, _, _ ->
      send(test, :events_read)
      {:ok, %{"events" => [], "seq" => 0, "source" => "feed"}}
    end)

    start_supervised!(SwarmFeed)
    start_supervised!(SubzeroSwarmDashboard.EventsFeed)
    assert_receive :events_read
    assert_receive :events_read, 1_000
    refute_received :dashboard_read
  end

  test "publishes only revisions and projects cached data before copying it to a reader" do
    snap = %{"sessions" => Enum.map(1..20_000, &%{"session_id" => "test:#{&1}:0"})}
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, snap} end)
    SwarmFeed.subscribe()
    start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, revision}, 2_000
    assert byte_size(:erlang.term_to_binary({:snapshot_ready, revision})) < 100
    assert SwarmFeed.current(fn cached -> length(cached["sessions"]) end) == 20_000
    refute_received {:snapshot, _}
  end

  test "cached reads stay available while one poll is waiting and preserve failure status" do
    parent = self()

    stub(SwarmClientMock, :dashboard, fn _ ->
      send(parent, {:poll_waiting, self()})

      receive do
        {:finish, result} -> result
      end
    end)

    SwarmFeed.subscribe()
    feed = start_supervised!(SwarmFeed)
    assert_receive {:poll_waiting, task}, 2_000
    assert SwarmFeed.current() == nil
    snap = %{"summary" => %{"agents" => 0}, "sessions" => []}
    send(task, {:finish, {:ok, snap}})
    assert_receive {:snapshot_ready, revision}, 2_000
    state = :sys.get_state(feed)
    send(feed, {:timeout, state.timer, :poll})
    assert_receive {:poll_waiting, next_task}, 2_000
    assert SwarmFeed.current() == snap
    send(next_task, {:finish, {:error, :timeout}})
    assert_receive {:disconnected, failed_revision, :timeout}, 2_000
    assert failed_revision > revision
    assert {:disconnected, ^failed_revision, _} = SwarmFeed.view(%{})
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
