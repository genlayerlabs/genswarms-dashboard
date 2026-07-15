defmodule SubzeroSwarmDashboard.Story.ReducerTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.Story.{Reducer, State}

  @cid "tg:5681202:0"
  @agent "wingston_agent_0"

  defp ev(kind, seq, ts, fields \\ %{}),
    do: Map.merge(%{"kind" => kind, "seq" => seq, "ts" => ts / 1}, fields)

  defp fold(events, state \\ State.new()),
    do: Enum.reduce(events, state, &Reducer.apply(&2, &1))

  describe "user labels resolve the @handle from put_users/2" do
    test "story rows and the episode carry the handle when the snapshot knew it" do
      state =
        State.new()
        |> Reducer.put_users(%{@cid => "kstellana"})
        |> then(
          &fold(
            [
              ev("request_open", 1, 100.0, %{"cid" => @cid}),
              ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
              ev("reply_sent", 3, 109.0, %{"cid" => @cid, "ok" => true})
            ],
            &1
          )
        )

      texts = Enum.map(state.story, & &1.text)
      assert Enum.any?(texts, &(&1 =~ "@kstellana request open"))
      assert Enum.any?(texts, &(&1 =~ "@kstellana replied in 9.0s"))
      refute Enum.any?(texts, &(&1 =~ "@5681202"))

      # the episode's user feeds topology's `@{ep.user}` (rendered raw, no join)
      assert [closed] = State.episodes(state, @cid)
      assert closed.user == "kstellana"
    end

    test "put_users re-stamps an already-open episode (first turn before first snapshot)" do
      # request_open folds before any snapshot → ep.user baked as the chat id
      state = fold([ev("request_open", 1, 100.0, %{"cid" => @cid})])
      assert [ep] = Map.values(state.open)
      assert ep.user == "5681202"

      # the snapshot lands; the OPEN episode picks up the handle (Topology reads it raw)
      state = Reducer.put_users(state, %{@cid => "kstellana"})
      assert [ep2] = Map.values(state.open)
      assert ep2.user == "kstellana"
    end

    test "falls back to the raw chat id for a cid the snapshot didn't include" do
      state =
        State.new()
        |> Reducer.put_users(%{"tg:999:0" => "someone-else"})
        |> then(&fold([ev("request_open", 1, 100.0, %{"cid" => @cid})], &1))

      assert Enum.any?(Enum.map(state.story, & &1.text), &(&1 =~ "@5681202 request open"))
    end
  end

  describe "swarm boot reconciliation" do
    test "drops only live state from before the current boot" do
      old_cid = "tg:1:0"
      new_cid = "tg:2:0"

      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => old_cid}),
          ev("routed", 2, 101.0, %{"cid" => old_cid, "slot" => "wingston_agent_1"}),
          ev("llm_proxy_block", 3, 150.0, %{"cid" => "tg:3:0", "reason" => "budget"}),
          ev("request_open", 4, 201.0, %{"cid" => new_cid}),
          ev("routed", 5, 202.0, %{"cid" => new_cid, "slot" => "wingston_agent_2"})
        ])

      state = Reducer.reconcile_boot(state, 200.0)

      refute Map.has_key?(state.open, old_cid)
      refute Map.has_key?(state.agents, "wingston_agent_1")
      assert Map.has_key?(state.open, new_cid)
      assert Map.has_key?(state.agents, "wingston_agent_2")
      assert [%{kind: "llm_proxy_block"}] = state.issues
      assert state.counters.stalled == 0
    end

    test "keeps evidence within the boot-time rounding tolerance" do
      state = fold([ev("request_open", 1, 199.5, %{"cid" => @cid})])
      assert Map.has_key?(Reducer.reconcile_boot(state, 200.0).open, @cid)
    end

    test "keeps a restored episode when the same cid opened again after boot" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("request_open", 2, 201.0, %{"cid" => @cid})
        ])

      assert state.open[@cid].opened_at == 100.0
      assert state.open[@cid].last_open == 201.0
      assert Map.has_key?(Reducer.reconcile_boot(state, 200.0).open, @cid)
    end
  end

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

  describe "teardown of a dead agent closes the open request (not a stall)" do
    test "an open request torn down is dropped as an issue, never ages into a stall" do
      state =
        State.new()
        |> Reducer.put_users(%{@cid => "kstellana"})
        |> then(
          &fold(
            [
              ev("request_open", 1, 100.0, %{"cid" => @cid}),
              ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
              # the agent died; ingress tears the slot down (H2), carrying the cid
              ev("teardown", 3, 102.0, %{"cid" => @cid, "slot" => @agent})
            ],
            &1
          )
        )

      # the open request was closed at teardown, not left orphaned
      assert state.open == %{}
      # surfaced honestly as an issue with the handle + "dropped" label
      assert [issue] = state.issues
      assert issue.text =~ "@kstellana dropped"
      assert issue.text =~ "agent torn down"
      # the agent slot is released
      assert state.agents[@agent].state == :idle

      # crucial regression guard: a tick far past stall_after_ms cannot resurrect it
      # as a stalled episode (the masquerade the fix removes)
      ticked = Reducer.tick(state, 100.0 + 10_000)
      assert ticked.open == %{}
    end

    test "a teardown with no open request is just a plain slot teardown" do
      state = fold([ev("teardown", 1, 100.0, %{"cid" => @cid, "slot" => @agent})])

      assert state.open == %{}
      assert state.issues == []
      assert hd(state.story).text =~ "#{@agent} torn down"
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
      assert state.agents[@agent].wait_on == "browser"

      state = fold([ev("browse_done", 4, 105.9, %{"agent" => @agent, "verdict" => "ok"})], state)

      assert state.agents[@agent].state == :thinking
      assert state.counters.browse_ok == 1
      assert state.counters.browse_total == 1
      assert hd(state.story).text =~ "browser ok in 3.9s"
      assert state.issues == []
    end

    test "a policy denial bumps browse_blocked apart from real failures" do
      state =
        fold([
          ev("browser_dispatch", 1, 100.0, %{"agent" => @agent}),
          ev("browser_done", 2, 101.0, %{"agent" => @agent, "verdict" => "not_allowed"}),
          ev("browser_dispatch", 3, 102.0, %{"agent" => @agent}),
          ev("browser_done", 4, 103.0, %{"agent" => @agent, "verdict" => "render_failed"})
        ])

      assert state.counters.browse_blocked == 1
      assert state.counters.browse_total == 2
      assert state.counters.browse_ok == 0
    end

    test "a failure verdict is an issue (and counts against the ok-rate)" do
      state =
        fold([
          ev("request_open", 1, 99.0, %{"cid" => @cid}),
          ev("routed", 2, 99.5, %{"cid" => @cid, "slot" => @agent}),
          ev("browse_dispatch", 3, 100.0, %{"agent" => @agent}),
          ev("browse_done", 4, 101.0, %{"agent" => @agent, "verdict" => "not_allowed"})
        ])

      assert state.counters.browse_ok == 0
      assert state.counters.browse_total == 1
      assert [issue] = state.issues
      assert issue.cid == @cid
      assert issue.text =~ "not_allowed"
      assert hd(state.story).issue
    end
  end

  describe "browse_* (legacy kind, pre-rename hosts)" do
    test "browse_dispatch/browse_done delegate into the browser folds identically" do
      state =
        fold([
          ev("browser_dispatch", 1, 100.0, %{"agent" => @agent, "url" => "https://x"}),
          ev("browser_done", 2, 103.0, %{"agent" => @agent, "verdict" => "ok"})
        ])

      assert state.counters.browse_total == 1
      assert state.counters.browse_ok == 1
      assert hd(state.story).text =~ "browser ok"
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

    test "a queued agent that decays to idle clears its stale queue count (no phantom badge)" do
      # busy agent with a queued follow-up: queue == 1, state thinking
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("request_open", 3, 104.0, %{"cid" => @cid}),
          ev("routed", 4, 104.1, %{"cid" => @cid, "slot" => @agent})
        ])

      assert state.agents[@agent].queue == 1
      assert state.agents[@agent].state == :thinking

      # decay runs on the wall-clock tick (not on event folds). A tick at t=200,
      # >think_decay_ms (60s) past the agent's last activity (104.1), decays the
      # thinking agent to idle. The stale queue MUST clear with it, else the canvas
      # keeps painting a phantom "queued turns" badge on an idle node.
      state = Reducer.tick(state, 200.0)

      assert state.agents[@agent].state == :idle
      assert state.agents[@agent].queue == 0
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

    test "an unrouted inbox rejection closes only that rejected request" do
      rejected =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("inbox_full", 2, 101.0, %{"cid" => @cid, "slot" => @agent})
        ])

      assert rejected.open == %{}
      assert [%{status: "rejected"}] = State.episodes(rejected, @cid)
      assert Reducer.tick(rejected, 1_000.0).counters.stalled == 0

      active =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("routed", 2, 100.5, %{"cid" => @cid, "slot" => @agent}),
          ev("request_open", 3, 101.0, %{"cid" => @cid}),
          ev("inbox_full", 4, 101.1, %{"cid" => @cid, "slot" => @agent})
        ])

      assert active.open[@cid].agent == @agent
    end

    test "suppression and LLM failure settle their open turns" do
      for {kind, fields, status} <- [
            {"reply_suppressed", %{}, "suppressed"},
            {"llm_error", %{"class" => "api"}, "llm_error"}
          ] do
        state =
          fold([
            ev("request_open", 1, 100.0, %{"cid" => @cid}),
            ev("routed", 2, 100.5, %{"cid" => @cid, "slot" => @agent}),
            ev(kind, 3, 101.0, Map.put(fields, "cid", @cid))
          ])

        assert state.open == %{}
        assert [%{status: ^status}] = State.episodes(state, @cid)
        assert state.agents[@agent].state == :idle
        assert Reducer.tick(state, 1_000.0).counters.stalled == 0
      end
    end

    test "push_failed is a failure issue naming the campaign; campaignless still folds" do
      state =
        fold([
          ev("push_failed", 1, 100.0, %{"cid" => @cid, "campaign" => "reach:abc123", "error" => "429"}),
          ev("push_failed", 2, 101.0, %{"cid" => @cid})
        ])

      assert state.counters.failures == 2
      assert [%{kind: "push_failed"}, %{kind: "push_failed", text: text}] = state.issues
      assert text =~ "reach:abc123"
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
      assert state.agents[@agent].wait_on == "browser"
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
      # a leg is a ROUTED turn landing mid-turn (coalesced same-batch messages
      # no longer count — they get one comprehensive reply), so the queued
      # follow-up here carries its own routed event
      state =
        fold(
          [
            ev("request_open", 1, 100.0, %{"cid" => @cid}),
            ev("routed", 2, 100.5, %{"cid" => @cid, "slot" => @agent}),
            ev("request_open", 3, 104.0, %{"cid" => @cid}),
            ev("routed", 4, 104.1, %{"cid" => @cid, "slot" => @agent})
          ],
          State.new(stall_after_ms: 5_000)
        )

      state = Reducer.tick(state, 106.0)
      assert state.counters.stalled == 1

      # leg close re-arms at 104.0 with a fresh stall flag
      state = fold([ev("reply_sent", 5, 107.0, %{"cid" => @cid, "ok" => true})], state)
      refute state.open[@cid].stalled

      state = Reducer.tick(state, 110.0)
      assert state.counters.stalled == 2
    end

    test "an episode stalled past the abandon horizon closes as abandoned" do
      state =
        fold(
          [
            ev("request_open", 1, 100.0, %{"cid" => @cid}),
            ev("routed", 2, 100.5, %{"cid" => @cid, "slot" => @agent})
          ],
          State.new(stall_after_ms: 5_000)
        )

      # stalls first (abandon horizon = 10 × the stall threshold = 50s)…
      state = Reducer.tick(state, 110.0)
      assert state.open[@cid].stalled

      # …then abandons: leaves In-Flight, closes with status "abandoned",
      # explains itself with a story row — but NOT a second issue (the stall
      # already told the story)
      state = Reducer.tick(state, 151.0)
      assert state.open == %{}
      assert [%{status: "abandoned", done: true}] = State.episodes(state, @cid)
      assert Enum.any?(state.story, &(&1.kind == "abandoned"))
      assert Enum.count(state.issues) == 1
    end

    test "the agents map is bounded — longest-idle slots are pruned past the cap" do
      events =
        Enum.flat_map(1..40, fn i ->
          [
            ev("spawn_start", i * 2 - 1, 100.0 + i, %{"slot" => "dyn_agent_#{i}"}),
            ev("teardown", i * 2, 100.5 + i, %{"slot" => "dyn_agent_#{i}"})
          ]
        end)

      state = fold(events)
      assert map_size(state.agents) == 40

      state = Reducer.tick(state, 200.0)
      assert map_size(state.agents) == 32
      # the most recently active slots survive; the oldest idle ones go
      assert Map.has_key?(state.agents, "dyn_agent_40")
      refute Map.has_key?(state.agents, "dyn_agent_1")
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

    test "stalled KPI is live while the durable counter remains cumulative" do
      state =
        fold(
          [ev("request_open", 1, 100.0, %{"cid" => @cid})],
          State.new(stall_after_ms: 5_000)
        )
        |> Reducer.tick(106.0)

      assert State.summary(state).kpis.stalled == 1
      assert state.counters.stalled == 1

      state = fold([ev("reply_sent", 2, 107.0, %{"cid" => @cid, "ok" => true})], state)
      assert State.summary(state).kpis.stalled == 0
      assert state.counters.stalled == 1
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

    test "spawning also decays after the longer silence window" do
      state = fold([ev("spawn_start", 1, 100.0, %{"slot" => @agent})])

      assert Reducer.tick(state, 350.0).agents[@agent].state == :spawning
      assert Reducer.tick(state, 401.0).agents[@agent].state == :idle
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
    test "a successful route moves a spawning slot into its first turn" do
      state =
        fold([
          ev("request_open", 1, 100.0, %{"cid" => @cid}),
          ev("spawn_start", 2, 100.2, %{"cid" => @cid, "slot" => @agent}),
          ev("routed", 3, 101.0, %{"cid" => @cid, "slot" => @agent})
        ])

      assert state.agents[@agent].state == :thinking
      assert state.agents[@agent].queue == 0
      assert Enum.any?(state.story, &(&1.text =~ "claims #{@cid}"))
      refute Enum.any?(state.story, &(&1.text =~ "queued behind current turn"))
    end
  end

  describe "coalesced burst (legs are routed turns, not messages)" do
    test "a 6-message burst answered by 3 replies leaves nothing open and never stalls" do
      # exact live sequence 2026-07-04 16:24 (feed seq 3..45): 6 request_open,
      # 2 routed turns, 3 replies. The old per-message leg counting left
      # count=3 open → false "stalled — no reply in 180.6s" + a forever-red
      # In-Flight row after every rapid-fire burst.
      state =
        fold([
          ev("spawn_start", 3, 100.0, %{"cid" => @cid, "slot" => @agent}),
          ev("request_open", 4, 100.1, %{"cid" => @cid}),
          ev("routed", 7, 101.0, %{"cid" => @cid, "slot" => @agent}),
          ev("request_open", 9, 102.0, %{"cid" => @cid}),
          ev("request_open", 12, 104.0, %{"cid" => @cid}),
          ev("request_open", 14, 106.0, %{"cid" => @cid}),
          ev("request_open", 19, 108.0, %{"cid" => @cid}),
          ev("request_open", 21, 109.0, %{"cid" => @cid}),
          ev("routed", 23, 109.5, %{"cid" => @cid, "slot" => @agent}),
          ev("reply_sent", 25, 111.0, %{"cid" => @cid, "ok" => true}),
          ev("reply_sent", 28, 117.0, %{"cid" => @cid, "ok" => true}),
          ev("reply_sent", 45, 168.0, %{"cid" => @cid, "ok" => true})
        ])

      assert state.open == %{}
      assert state.counters.stalled == 0

      # and the wall-clock stall sweep finds nothing to flag
      swept = Reducer.tick(state, 999.0)
      assert swept.counters.stalled == 0
    end
  end

  describe "package incident kinds (registry parity)" do
    test "proc_crash renders an issue naming the crashed module" do
      state = fold([ev("proc_crash", 1, 100.0, %{"module" => "Wingston.Worker"})])
      assert [%{kind: "proc_crash", issue: true, text: text}] = state.issues
      assert text =~ "Wingston.Worker"
    end

    test "llm_proxy_block renders an issue row naming the cap" do
      state = fold([ev("llm_proxy_block", 1, 100.0, %{"cid" => @cid, "reason" => "budget"})])
      assert [row] = state.story
      assert row.issue
      assert row.text =~ "LLM blocked (budget cap)"
    end

    test "llm_proxy_degraded renders an issue row naming the path" do
      state = fold([ev("llm_proxy_degraded", 1, 100.0, %{"cid" => @cid, "path" => "usage_store"})])
      assert [row] = state.story
      assert row.issue
      assert row.text =~ "budget store degraded (usage_store)"
    end

    test "ok cron runs stay off the story; failures and breaker pauses are issue rows" do
      ok = fold([ev("job_run", 1, 100.0, %{"name" => "tips", "status" => "ok"})])
      assert ok.story == []

      bad =
        fold([
          ev("job_run", 1, 100.0, %{"name" => "outreach", "status" => "error"}),
          ev("job_run", 2, 101.0, %{"name" => "outreach", "status" => "breaker_paused"})
        ])

      texts = Enum.map(bad.story, & &1.text)
      assert Enum.any?(texts, &(&1 =~ "cron outreach → error"))
      assert Enum.any?(texts, &(&1 =~ "cron outreach → breaker_paused"))
      assert Enum.all?(bad.story, & &1.issue)
    end
  end
end
