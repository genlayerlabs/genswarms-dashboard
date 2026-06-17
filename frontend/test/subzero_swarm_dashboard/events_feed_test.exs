defmodule SubzeroSwarmDashboard.EventsFeedTest do
  use ExUnit.Case, async: false
  import Mox

  alias SubzeroSwarmDashboard.{EventsFeed, SwarmClientMock}

  setup :set_mox_global

  setup do
    Application.put_env(:subzero_swarm_dashboard, :events_poll_ms, 10)
    on_exit(fn -> Application.delete_env(:subzero_swarm_dashboard, :events_poll_ms) end)
    :ok
  end

  defp evt(seq, kind, fields),
    do: Map.merge(%{"seq" => seq, "kind" => kind, "ts" => 1_000.0 + seq}, fields)

  defp feed(events, seq), do: {:ok, %{"events" => events, "seq" => seq, "source" => "feed"}}

  # Scripted by `since` (stable across repeated polls — no expectation counting
  # races with the poll loop). Each call also reports the cursor it was given.
  defp script(replies) do
    test = self()

    stub(SwarmClientMock, :events_feed, fn "wingston", since, limit ->
      send(test, {:polled, since, limit})
      Map.fetch!(replies, since)
    end)
  end

  test "first poll baselines the cursor — history is discarded, never replayed" do
    script(%{
      0 => feed([evt(41, "request_open", %{"cid" => "tg:1:0"})], 42),
      42 => feed([evt(43, "request_open", %{"cid" => "tg:9:0"})], 43),
      43 => feed([], 43)
    })

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    assert_receive {:polled, 0, 500}
    assert_receive {:story, %{feed_status: :ok}}

    # the cursor advanced to the baselined seq, and only post-baseline
    # events are broadcast (seq 41 was pre-boot history)
    assert_receive {:polled, 42, 500}
    assert_receive {:display_event, %{"seq" => 43}}
    refute_received {:display_event, %{"seq" => 41}}
    assert_receive {:polled, 43, 500}
  end

  test "story summaries tick on EVERY poll, including empty ones" do
    script(%{0 => feed([], 7), 7 => feed([], 7)})

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    assert_receive {:story, %{feed_status: :ok}}
    assert_receive {:story, %{feed_status: :ok}}
    assert_receive {:story, %{feed_status: :ok}}
  end

  test "a seq gap folds a feed_gap issue and keeps going" do
    script(%{
      0 => feed([], 10),
      # first new event jumps to 15: 4 events were pruned while we lagged
      10 => feed([evt(15, "request_open", %{"cid" => "tg:1:0"})], 16),
      16 => feed([], 16)
    })

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    assert_receive {:story, %{issues: [%{kind: "feed_gap", text: text} | _]}}
    assert text =~ "4 event(s) lost"
    # the gapped batch itself is still folded + broadcast
    assert_receive {:display_event, %{"seq" => 15}}
    assert_receive {:polled, 16, 500}
  end

  test "a cursor regression re-baselines and resets since-baseline state" do
    script(%{
      0 => feed([], 100),
      100 => feed([evt(101, "request_open", %{"cid" => "tg:1:0"})], 101),
      # the feed restarted: its cursor came back far below ours
      101 => feed([evt(1, "request_open", %{"cid" => "tg:2:0"})], 3),
      3 => feed([], 3)
    })

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    # state built before the restart…
    assert_receive {:story, %{in_flight: [%{cid: "tg:1:0"}]}}
    # …is reset, with the restart noted in the story
    assert_receive {:story, %{in_flight: [], story: [%{kind: "feed_restart"} | _]}}
    assert_receive {:polled, 3, 500}
  end

  test "an unavailable source degrades the status and keeps polling" do
    test = self()

    stub(SwarmClientMock, :events_feed, fn "wingston", since, _limit ->
      send(test, {:polled, since})
      {:ok, %{"events" => [], "seq" => 0, "source" => "unavailable"}}
    end)

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    assert_receive {:story, %{feed_status: :unavailable}}
    # never baselined: it keeps asking from 0
    assert_receive {:polled, 0}
    assert_receive {:polled, 0}
  end

  test "an HTTP error degrades the status the same way" do
    stub(SwarmClientMock, :events_feed, fn _, _, _ -> {:error, :econnrefused} end)

    EventsFeed.subscribe()
    start_supervised!(EventsFeed)

    assert_receive {:story, %{feed_status: :unavailable}}
  end

  test "a /dashboard snapshot feeds the cid→handle map into the story state" do
    script(%{0 => feed([], 0)})

    EventsFeed.subscribe()
    pid = start_supervised!(EventsFeed)
    assert_receive {:story, %{feed_status: :ok}}

    Phoenix.PubSub.broadcast(
      SubzeroSwarmDashboard.PubSub,
      "feed",
      {:snapshot,
       %{
         "sessions" => [
           %{"session_id" => "tg:5681202:0", "user" => %{"handle" => "kstellana"}},
           # robustness: a not-yet-rostered live session (user: nil) and a
           # malformed row (no user) are skipped, not crashed on
           %{"session_id" => "tg:9:0", "user" => nil},
           %{"session_id" => "tg:8:0"}
         ]
       }}
    )

    state = :sys.get_state(pid)
    assert state.story.users == %{"tg:5681202:0" => "kstellana"}
  end

  test "other feed-topic traffic (live events, disconnects) is ignored, not crashed on" do
    script(%{0 => feed([], 0)})

    pid = start_supervised!(EventsFeed)

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:event, "agent_output", %{}})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:disconnected, :boom})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:warning, :endpoint_not_colocated})

    # still alive and well after the catch-all handler
    assert is_map(:sys.get_state(pid))
    assert Process.alive?(pid)
  end

  test "story_ring/0 and episodes/1 expose the full fold on demand" do
    cid = "tg:1:0"

    script(%{
      0 => feed([], 10),
      10 =>
        feed(
          [
            evt(11, "request_open", %{"cid" => cid}),
            evt(12, "routed", %{"cid" => cid, "slot" => "wingston_agent_0"}),
            evt(13, "reply_sent", %{"cid" => cid, "ok" => true})
          ],
          13
        ),
      13 => feed([], 13)
    })

    EventsFeed.subscribe()
    pid = start_supervised!(EventsFeed)

    # wait for the close to be folded, then drain the mailbox-synchronous call
    assert_receive {:story, %{kpis: %{replies: 1}}}, 1_000
    _ = :sys.get_state(pid)

    ring = EventsFeed.story_ring()
    assert Enum.any?(ring, &(&1.text =~ "replied in"))

    assert [%{done: true, agent: "wingston_agent_0"}] = EventsFeed.episodes(cid)
    assert EventsFeed.episodes("tg:nobody:9") == []
  end
end
