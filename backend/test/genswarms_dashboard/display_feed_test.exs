defmodule GenswarmsDashboard.DisplayFeedTest.MemoryStore do
  @behaviour GenswarmsDashboard.DisplayFeed.Store

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts) do
    Agent.start_link(fn -> initial() end, name: __MODULE__)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> initial() end)

  def put_events(events) when is_list(events) do
    Agent.update(__MODULE__, &%{&1 | events: events})
  end

  def fail_append(flag), do: Agent.update(__MODULE__, &%{&1 | fail_append?: flag})

  def events, do: Agent.get(__MODULE__, & &1.events)

  @impl true
  def append_display_events(batch) do
    if Agent.get(__MODULE__, & &1.fail_append?) do
      raise "append failed"
    end

    Agent.update(__MODULE__, &%{&1 | events: &1.events ++ batch})
    :ok
  end

  @impl true
  def load_recent_display_events(limit) do
    Agent.get(__MODULE__, &Enum.take(&1.events, -limit))
  end

  defp initial, do: %{events: [], fail_append?: false}
end

defmodule GenswarmsDashboard.DisplayFeedTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias GenswarmsDashboard.DisplayFeed
  alias GenswarmsDashboard.DisplayFeedTest.MemoryStore

  setup do
    start_supervised!(MemoryStore)
    MemoryStore.reset()

    suffix = System.unique_integer([:positive])

    feed = %{
      name: :"#{__MODULE__}.Feed#{suffix}",
      table: :"#{__MODULE__}.Table#{suffix}",
      telemetry_event: [:"display_feed_test_#{suffix}", :display]
    }

    on_exit(fn ->
      case Process.whereis(feed.name) do
        nil -> :ok
        _pid -> GenServer.stop(feed.name, :normal, 1_000)
      end
    end)

    {:ok, feed: feed}
  end

  test "persists and rehydrates gapless seqs across restart with pinned cursor semantics", %{
    feed: feed
  } do
    start_feed!(feed, store: MemoryStore, flush_size: 1)

    emit(feed, %{kind: :request_open, cid: "c1"})
    emit(feed, %{kind: :routed, cid: "c1", slot: :agent_1})
    DisplayFeed.sync(feed.name)

    assert {events, 2} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [1, 2]
    assert Enum.map(events, & &1.kind) == ["request_open", "routed"]
    assert {[], 2} = DisplayFeed.since(feed.table, 2, 10)

    GenServer.stop(feed.name)

    start_feed!(feed, store: MemoryStore, flush_size: 1)
    DisplayFeed.sync(feed.name)

    assert {events, 3} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [1, 2, 3]
    assert List.last(events).kind == "feed_rehydrated"
    assert List.last(events).count == 2

    emit(feed, %{kind: :reply_sent, cid: "c1", ok: true})
    DisplayFeed.sync(feed.name)

    assert {events, 4} = DisplayFeed.since(feed.table, 2, 10)
    assert Enum.map(events, & &1.seq) == [3, 4]
    assert Enum.map(events, & &1.kind) == ["feed_rehydrated", "reply_sent"]
    assert {[], 4} = DisplayFeed.since(feed.table, 999, 10)
  end

  test "store nil keeps ring-only behavior and restart resets the in-memory feed", %{feed: feed} do
    start_feed!(feed, store: nil)

    emit(feed, %{kind: :request_open})
    emit(feed, %{kind: :typing})
    DisplayFeed.sync(feed.name)

    assert {events, 2} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [1, 2]
    assert Enum.map(events, & &1.kind) == ["request_open", "typing"]
    assert {[], 2} = DisplayFeed.since(feed.table, 2, 10)

    GenServer.stop(feed.name)

    start_feed!(feed, store: nil)
    assert {[], 0} = DisplayFeed.since(feed.table, 99, 10)

    emit(feed, %{kind: :reply_sent})
    DisplayFeed.sync(feed.name)

    assert {events, 1} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [1]
  end

  test "flush failures are logged and dropped without killing the ring", %{feed: feed} do
    start_feed!(feed, store: MemoryStore, flush_size: 1)
    MemoryStore.fail_append(true)

    log =
      capture_log(fn ->
        emit(feed, %{kind: :request_open, cid: "c1"})
        DisplayFeed.sync(feed.name)
      end)

    assert log =~ "display flush dropped 1 events"
    assert log =~ "append failed"
    assert Process.alive?(Process.whereis(feed.name))
    assert MemoryStore.events() == []
    assert {events, 1} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.kind) == ["request_open"]

    MemoryStore.fail_append(false)
    emit(feed, %{kind: :reply_sent, cid: "c1"})
    DisplayFeed.sync(feed.name)

    assert Enum.map(MemoryStore.events(), & &1.seq) == [2]
    assert {events, 2} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [1, 2]
  end

  test "ring cap is enforced after rehydrate and after the feed_rehydrated marker", %{feed: feed} do
    MemoryStore.put_events([
      persisted(1, "one"),
      persisted(2, "two"),
      persisted(3, "three"),
      persisted(4, "four"),
      persisted(5, "five")
    ])

    start_feed!(feed, store: MemoryStore, ring: 3, flush_ms: 0)

    assert {events, 6} = DisplayFeed.since(feed.table, 0, 10)
    assert Enum.map(events, & &1.seq) == [4, 5, 6]
    assert Enum.map(events, & &1.kind) == ["four", "five", "feed_rehydrated"]
    assert List.last(events).count == 3
  end

  test "rehydrate keeps unknown string keys as strings with to_existing_atom fallback", %{
    feed: feed
  } do
    unknown = "display_feed_unknown_#{System.unique_integer([:positive])}"
    nested_unknown = "display_feed_nested_#{System.unique_integer([:positive])}"
    fixture_keys = ~w(i j k ratio nested list ref atom)

    MemoryStore.put_events([
      Map.merge(
        %{
          "seq" => "9",
          "ts" => 1_718_000_000.0,
          "kind" => "loaded",
          unknown => %{nested_unknown => true}
        },
        Map.new(fixture_keys, &{&1, "fixture"})
      )
    ])

    start_feed!(feed, store: MemoryStore, flush_ms: 0)

    assert {[loaded, marker], 10} = DisplayFeed.since(feed.table, 0, 10)
    assert loaded.seq == 9
    assert loaded.kind == "loaded"
    assert loaded[unknown] == %{nested_unknown => true}
    refute Map.has_key?(loaded, String.to_atom(unknown))
    refute Map.has_key?(loaded[unknown], String.to_atom(nested_unknown))

    for key <- fixture_keys do
      assert loaded[key] == "fixture"

      case existing_atom(key) do
        {:ok, atom} -> refute Map.has_key?(loaded, atom)
        :error -> :ok
      end
    end

    assert marker.kind == "feed_rehydrated"
  end

  defp start_feed!(feed, opts) do
    opts =
      Keyword.merge(
        [
          name: feed.name,
          table: feed.table,
          telemetry_event: feed.telemetry_event,
          flush_ms: 0
        ],
        opts
      )

    {:ok, pid} = DisplayFeed.start_link(opts)
    pid
  end

  defp emit(feed, meta) do
    :telemetry.execute(feed.telemetry_event, %{}, meta)
  end

  defp persisted(seq, kind) do
    %{"seq" => seq, "ts" => 1_718_000_000.0 + seq, "kind" => kind}
  end

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end
