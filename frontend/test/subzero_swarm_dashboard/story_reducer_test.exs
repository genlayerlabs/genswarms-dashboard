defmodule SubzeroSwarmDashboard.Story.ReducerTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.Story.{Reducer, State}

  @cid "tg:5681202:0"
  @agent "wingston_agent_0"

  defp ev(kind, seq, ts, fields \\ %{}),
    do: Map.merge(%{"kind" => kind, "seq" => seq, "ts" => ts / 1}, fields)

  defp fold(events, state \\ State.new()),
    do: Enum.reduce(events, state, &Reducer.apply(&2, &1))

  describe "single request lifecycle" do
    test "a failed delivery (ok: false) never stamps first-feedback — the user saw nothing" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("reply_sent", 3, 105.0, %{"cid" => @cid, "ok" => false}),
          ev("reply_sent", 4, 109.0, %{"cid" => @cid, "ok" => true})
        ])

      # first-feedback samples only the ok send (9.0s), not the failed one (5.0s)
      assert [ff] = state.counters.first_feedback_durations
      assert_in_delta ff, 9.0, 0.001
    end

    test "open → routed → reply closes with the exact event-ts duration" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("reply_sent", 3, 109.0, %{"cid" => @cid, "ok" => true, "threaded" => true})
        ])

      assert state.open == %{}
      assert [closed] = State.episodes(state, @cid)
      assert closed.done
      assert closed.status == "replied"
      assert closed.agent == @agent
      assert_in_delta closed.duration, 9.0, 0.001

      assert state.counters.replies == 1
      assert [dur] = state.counters.reply_durations
      assert_in_delta dur, 9.0, 0.001
      # the reply was also the first thing the user saw
      assert [ff] = state.counters.first_feedback_durations
      assert_in_delta ff, 9.0, 0.001
      # agent released to idle (nothing queued)
      assert state.agents[@agent].state == :idle

      texts = Enum.map(state.story, & &1.text)
      assert Enum.any?(texts, &(&1 =~ "@5681202 request open"))
      assert Enum.any?(texts, &(&1 =~ "claims #{@cid}"))
      assert Enum.any?(texts, &(&1 =~ "replied in 9.0s"))
    end

    test "first feedback samples the FIRST progress only" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("progress_sent", 2, 103.1, %{"cid" => @cid}),
          ev("progress_sent", 3, 105.0, %{"cid" => @cid}),
          ev("reply_sent", 4, 109.0, %{"cid" => @cid, "ok" => true})
        ])

      assert [ff] = state.counters.first_feedback_durations
      assert_in_delta ff, 3.1, 0.001
      ff_p50 = State.summary(state).kpis.first_feedback_p50
      assert_in_delta ff_p50, 3.1, 0.001
    end
  end

  describe "browse" do
    test "dispatch parks the agent on browse; done resumes with the exact wait" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("browse_dispatch", 3, 102.0, %{"agent" => @agent, "url" => "https://x"})
        ])

      assert state.agents[@agent].state == :waiting
      assert state.agents[@agent].wait_on == "browse"

      state = fold([ev("browse_done", 4, 105.9, %{"agent" => @agent, "verdict" => "ok"})], state)

      assert state.agents[@agent].state == :thinking
      assert state.counters.browse_ok == 1
      assert state.counters.browse_total == 1
      assert hd(state.story).text =~ "browse ok in 3.9s"
      assert state.issues == []
    end

    test "a failure verdict is an issue (and counts against the ok-rate)" do
      state =
        fold([
          ev("browse_dispatch", 1, 100.0, %{"agent" => @agent}),
          ev("browse_done", 2, 101.0, %{"agent" => @agent, "verdict" => "not_allowed"})
        ])

      assert state.counters.browse_ok == 0
      assert state.counters.browse_total == 1
      assert [issue] = state.issues
      assert issue.text =~ "not_allowed"
      assert hd(state.story).issue
    end
  end

  describe "queued follow-up" do
    test "merges into the open episode, leg-closes, then closes for real" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("request_open", 3, 104.0, %{"cid" => @cid}),
          ev("routed", 4, 104.1, %{"cid" => @cid, "slot" => @agent})
        ])

      assert state.open[@cid].count == 2
      assert state.open[@cid].last_open == 104.0
      # the second routed found the agent busy: queued, not re-claimed
      assert state.agents[@agent].queue == 1
      assert hd(state.story).text =~ "queued behind current turn"

      state = fold([ev("reply_sent", 5, 109.0, %{"cid" => @cid, "ok" => true})], state)

      # leg close: the first request closed exact, the follow-up re-armed
      open = state.open[@cid]
      assert open.count == 1
      assert open.opened_at == 104.0
      assert open.first_sent == nil
      assert open.agent == @agent
      assert hd(state.story).text =~ "+1 queued"
      assert state.counters.replies == 1
      assert [closed] = Enum.filter(state.closed, &(&1.cid == @cid))
      assert_in_delta closed.duration, 9.0, 0.001
      # queue drains back into the turn
      assert state.agents[@agent].queue == 0
      assert state.agents[@agent].state == :thinking

      state = fold([ev("reply_sent", 6, 112.0, %{"cid" => @cid, "ok" => true})], state)

      assert state.open[@cid] == nil
      assert [leg2, leg1] = State.episodes(state, @cid)
      assert_in_delta leg2.duration, 8.0, 0.001
      assert_in_delta leg1.duration, 9.0, 0.001
      assert state.counters.replies == 2
      assert state.agents[@agent].state == :idle
    end
  end

  describe "multi-user burst" do
    test "attributes each request by its routed slot, never by adjacency" do
      a = "tg:111:0"
      b = "tg:222:0"

      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => a}),
          ev("request_open", 2, 100.2, %{"cid" => b}),
          ev("routed", 3, 100.5, %{"cid" => a, "slot" => "wingston_agent_0"}),
          ev("routed", 4, 100.7, %{"cid" => b, "slot" => "wingston_agent_1"}),
          ev("reply_sent", 5, 105.0, %{"cid" => b, "ok" => true})
        ])

      assert state.open[a].agent == "wingston_agent_0"
      assert state.open[b] == nil
      assert [closed] = State.episodes(state, b)
      assert closed.agent == "wingston_agent_1"
      assert_in_delta closed.duration, 4.8, 0.001
      # only b's agent was released
      assert state.agents["wingston_agent_1"].state == :idle
      assert state.agents["wingston_agent_0"].state == :thinking
    end
  end

  describe "issues" do
    test "inbox_full is an issue + counter, episodes untouched" do
      state = fold([ev("inbox_full", 1, 100.0, %{"cid" => @cid, "slot" => @agent})])

      assert state.counters.inbox_full == 1
      assert [%{kind: "inbox_full"}] = state.issues
      assert hd(state.story).issue
      assert state.open == %{}
    end

    test "reply_sent ok:false and reply_failed are failures" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("reply_sent", 2, 105.0, %{"cid" => @cid, "ok" => false}),
          ev("reply_failed", 3, 106.0, %{"from" => @agent})
        ])

      assert state.counters.failures == 2
      # a failed delivery does NOT close the episode
      assert state.open[@cid]
      assert [%{kind: "reply_failed"}, %{kind: "reply_sent"}] = state.issues
    end

    test "inbox_dropped idles the slot and reports the lost count" do
      state =
        fold([
          ev("browse_dispatch", 1, 100.0, %{"agent" => @agent}),
          ev("inbox_dropped", 2, 101.0, %{"agent" => @agent, "count" => 3})
        ])

      assert state.agents[@agent].state == :idle
      assert [issue] = state.issues
      assert issue.text =~ "3 task(s) lost"
    end

    test "feed_gap folds an issue with the lost count" do
      state = fold([ev("feed_gap", nil, 100.0, %{"lost" => 4})])

      assert [issue] = state.issues
      assert issue.kind == "feed_gap"
      assert issue.text =~ "4 event(s) lost"
      assert state.counters.feed_gaps == 1
    end
  end

  describe "compaction mid-wait" do
    test "notes the story but leaves the wait untouched" do
      state =
        fold([
          ev("browse_dispatch", 1, 100.0, %{"agent" => @agent}),
          ev("compaction", 2, 101.0, %{"cid" => @cid})
        ])

      assert state.agents[@agent].state == :waiting
      assert state.agents[@agent].wait_on == "browse"
      assert state.counters.compactions == 1
      assert hd(state.story).text =~ "compacting"
      assert state.issues == []
    end
  end

  describe "compatibility (spec §2: kinds are additive)" do
    test "an unknown kind folds to a generic story row, state otherwise untouched" do
      base = fold([ev("request_open", 1, 100.0, %{"cid" => @cid})])
      state = fold([ev("orbital_laser", 2, 101.0, %{"cid" => @cid, "deep" => %{"x" => 1}})], base)

      assert hd(state.story).text =~ "orbital_laser"
      assert %{state | story: base.story} == base
    end

    test "known kinds with missing fields never crash" do
      state =
        fold([
          ev("request_open", 1, 100.0),
          ev("routed", 2, 101.0),
          ev("reply_sent", 3, 102.0),
          ev("browse_done", 4, 103.0),
          %{"kind" => nil},
          %{}
        ])

      assert %State{} = state
    end

    test "typing and proactive_sent are canvas packets only" do
      state =
        fold([
          ev("typing", 1, 100.0, %{"cid" => @cid}),
          ev("proactive_sent", 2, 101.0, %{"cid" => @cid})
        ])

      assert state == State.new()
    end
  end

  describe "tick/2" do
    test "refreshes in-flight elapsed via the feed-anchored now" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 100.5, %{"cid" => @cid, "slot" => @agent})
        ])

      state = Reducer.tick(state, 112.4)

      assert [row] = State.summary(state).in_flight
      assert_in_delta row.elapsed_s, 12.4, 0.001
      assert row.agent == @agent
      assert row.activity == "thinking"
    end

    test "classifies a stalled episode exactly once" do
      state =
        fold(
          [ev("request_open", 1, 100.0, %{"cid" => @cid})],
          State.new(stall_after_ms: 5_000)
        )

      state = Reducer.tick(state, 104.0)
      assert state.issues == []

      state = Reducer.tick(state, 106.0)
      assert [%{kind: "stalled"}] = state.issues
      assert state.counters.stalled == 1
      # dual-ring: the stalled row also lands in the story ring (Events view)
      assert [%{kind: "stalled", cid: @cid, issue: true}] =
               Enum.filter(state.story, &(&1.kind == "stalled"))

      state = Reducer.tick(state, 120.0)
      assert [%{kind: "stalled"}] = state.issues
      assert state.counters.stalled == 1
      assert Enum.count(state.story, &(&1.kind == "stalled")) == 1
    end

    test "a re-armed follow-up leg can stall again" do
      state =
        fold(
          [
            ev("request_open", 1, 100.0, %{"cid" => @cid}),
            ev("request_open", 2, 104.0, %{"cid" => @cid})
          ],
          State.new(stall_after_ms: 5_000)
        )

      state = Reducer.tick(state, 106.0)
      assert state.counters.stalled == 1

      # leg close re-arms at 104.0 with a fresh stall flag
      state = fold([ev("reply_sent", 3, 107.0, %{"cid" => @cid, "ok" => true})], state)
      refute state.open[@cid].stalled

      state = Reducer.tick(state, 110.0)
      assert state.counters.stalled == 2
    end

    test "expires issues older than 24h (counters keep going)" do
      state = fold([ev("inbox_full", 1, 100.0, %{"cid" => @cid, "slot" => @agent})])

      state = Reducer.tick(state, 100.0 + 86_399)
      assert length(state.issues) == 1

      state = Reducer.tick(state, 100.0 + 86_401)
      assert state.issues == []
      assert state.counters.inbox_full == 1
    end
  end

  describe "KPI math" do
    test "reply p50/p95 are nearest-rank over event-ts durations" do
      events =
        Enum.flat_map(1..20, fn i ->
          cid = "tg:#{i}:0"

          [
            ev("request_open", i * 10, 1000.0 + i, %{"cid" => cid}),
            ev("reply_sent", i * 10 + 1, 1000.0 + i + i, %{"cid" => cid, "ok" => true})
          ]
        end)

      kpis = State.summary(fold(events)).kpis
      assert kpis.replies == 20
      assert_in_delta kpis.reply_p50, 10.0, 0.001
      assert_in_delta kpis.reply_p95, 19.0, 0.001
    end

    test "percentile/2 nearest-rank corner cases" do
      assert State.percentile([], 0.5) == nil
      assert State.percentile([5.0], 0.95) == 5.0
      assert State.percentile([4.0, 2.0, 3.0, 1.0], 0.5) == 2.0
    end
  end

  describe "ring bounds" do
    test "the story ring is capped" do
      state =
        1..5
        |> Enum.map(&ev("request_open", &1, 100.0 + &1, %{"cid" => "tg:#{&1}:0"}))
        |> fold(State.new(story_max: 3))

      assert length(state.story) == 3
      assert hd(state.story).text =~ "@5"
    end
  end

  describe "activity decay (turn-end is invisible — never claim stale activity)" do
    test "thinking decays to idle after think_decay_ms without agent events" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("reply_sent", 3, 109.0, %{"cid" => @cid, "ok" => true}),
          # the post-reply ask that used to stick "thinking" forever
          ev("ask", 4, 110.0, %{"from" => @agent})
        ])

      assert state.agents[@agent].state == :thinking

      # 59s of silence — still honest to claim thinking
      state = Reducer.tick(state, 169.0)
      assert state.agents[@agent].state == :thinking

      # activity refreshes the decay clock without resetting the thinking start
      state = fold([ev("ask", 5, 169.5, %{"from" => @agent})], state)
      state = Reducer.tick(state, 228.0)
      assert state.agents[@agent].state == :thinking

      # 61.5s past the last evidence → stop claiming; since resets to that evidence
      state = Reducer.tick(state, 231.0)
      assert state.agents[@agent].state == :idle
      assert state.agents[@agent].since == 169.5
    end

    test "waiting decays only after the longer wait_decay_ms (a lost browse_done)" do
      state = fold([ev("browse_dispatch", 1, 100.0, %{"agent" => @agent, "url" => "https://x"})])

      state = Reducer.tick(state, 350.0)
      assert state.agents[@agent].state == :waiting

      state = Reducer.tick(state, 401.0)
      assert state.agents[@agent].state == :idle
    end
  end

  describe "chatter" do
    test "chatter events are canvas-only — no story row, no state, no counters" do
      state = fold([ev("chatter", 1, 100.0, %{"from" => "rally", "to" => "policy"})])
      assert state.story == []
      assert state.agents == %{}
    end
  end

  describe "spawning claims" do
    test "a claim routed to a spawning slot reads 'queued while spawning'" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("spawn_start", 2, 100.2, %{"cid" => @cid, "slot" => @agent}),
          ev("routed", 3, 101.0, %{"cid" => @cid, "slot" => @agent})
        ])

      assert Enum.any?(state.story, &(&1.text =~ "queued while spawning"))
      refute Enum.any?(state.story, &(&1.text =~ "queued behind current turn"))
    end
  end
end
