defmodule SubzeroSwarmDashboard.Story.Kinds do
  @moduledoc """
  The MACHINE-READABLE event-kind registry — single source of truth for the
  display-event vocabulary, enforced by `story_kinds_parity_test.exs`.

  The same vocabulary is hand-maintained in several layers (package emitters,
  the host registry table in wingston's `objects/event_feed.ex`, the reducer's
  folds, the Events-page filter, the canvas JS switch). Three shipped incidents
  came from one layer drifting (the telegram-cutover silence, the browse→browser
  rename, the canvas missing the renamed kinds). Every kind added or renamed
  MUST be added here; the parity tests then fail on any layer that lags.

  Per kind:
    * `sample` — the extra fields a well-formed event of this kind carries
      (merged onto `%{"kind", "seq", "ts"}`); the reducer parity test folds it
      and asserts the disposition below, so a sample missing a required field
      fails loudly.
    * `story:` — the fold bakes a story row (false = canvas/no-op by design:
      typing, proactive_sent, chatter — and ok job_runs, see note).
    * `canvas:` — pipeline.js animates it (a `case "kind"` or an intake
      normalization mentioning it). `false` means the canvas deliberately
      ignores it (llm_proxy_degraded has no geometry — no llm node exists).

  Ordered list, not a map — the Events-page filter dropdown renders in this
  order (lifecycle first, incidents after, synthetics last).
  """

  # ── wire kinds: emitted by the host/packages, arrive via the events feed ────
  @wire [
    {"request_open", %{sample: %{"cid" => "tg:1:0"}, story: true, canvas: true}},
    # routed only rows against an OPEN episode — `pre:` seeds it for the parity fold
    {"routed",
     %{
       pre: [%{"kind" => "request_open", "cid" => "tg:1:0", "seq" => 0, "ts" => 99.0}],
       sample: %{"cid" => "tg:1:0", "slot" => "wingston_agent_0"},
       story: true,
       canvas: true
     }},
    {"spawn_start", %{sample: %{"slot" => "wingston_agent_0"}, story: true, canvas: true}},
    {"teardown", %{sample: %{"slot" => "wingston_agent_0"}, story: true, canvas: true}},
    {"inbox_full", %{sample: %{}, story: true, canvas: true}},
    {"ask", %{sample: %{"from" => "wingston_agent_0"}, story: true, canvas: true}},
    # browser_* are the wire names since the browse→browser rename (browser
    # pkg 0.1.0); the reducer/canvas keep internal browse_* delegation shims
    {"browser_dispatch",
     %{
       sample: %{"agent" => "wingston_agent_0", "url" => "https://example.com"},
       story: true,
       canvas: true
     }},
    {"browser_done",
     %{sample: %{"agent" => "wingston_agent_0", "verdict" => "ok"}, story: true, canvas: true}},
    # runtime allowlist grant (browser pkg 0.2.0 allow_sync): the grantor is an
    # object, not an agent slot — audit row only, no canvas geometry
    {"browser_grant",
     %{sample: %{"host" => "docs.example.com", "source" => "rally"}, story: true, canvas: false}},
    {"progress_sent", %{sample: %{"cid" => "tg:1:0"}, story: true, canvas: true}},
    {"reply_sent", %{sample: %{"cid" => "tg:1:0", "ok" => true}, story: true, canvas: true}},
    {"reply_failed", %{sample: %{"from" => "wingston_agent_0"}, story: true, canvas: true}},
    {"reply_suppressed", %{sample: %{"cid" => "tg:1:0"}, story: true, canvas: true}},
    {"llm_error", %{sample: %{"cid" => "tg:1:0", "class" => "api"}, story: true, canvas: true}},
    {"llm_proxy_block",
     %{sample: %{"cid" => "tg:1:0", "reason" => "budget"}, story: true, canvas: true}},
    # no llm node in the pipeline layout → nothing honest to animate
    {"llm_proxy_degraded", %{sample: %{"path" => "/v1/messages"}, story: true, canvas: false}},
    # sample uses a FAILED run: ok runs are story-silent by design (they fire
    # every few minutes) but still reach the canvas (cron ✓ float)
    {"job_run", %{sample: %{"name" => "daily_tip", "status" => "error"}, story: true, canvas: true}},
    {"compaction", %{sample: %{"cid" => "tg:1:0"}, story: true, canvas: true}},
    {"inbox_dropped",
     %{sample: %{"agent" => "wingston_agent_0", "count" => 2}, story: true, canvas: true}},
    # canvas-only by design: story rows for these would drown the ring
    {"typing", %{sample: %{"cid" => "tg:1:0"}, story: false, canvas: true}},
    {"proactive_sent", %{sample: %{"cid" => "tg:1:0"}, story: false, canvas: true}},
    {"chatter", %{sample: %{"from" => "policy", "to" => "rally"}, story: false, canvas: true}}
  ]

  # ── synthetic kinds: never on the wire ───────────────────────────────────────
  # folded: EventsFeed builds the event and runs it through Reducer.apply
  @folded_synthetic [
    {"feed_gap", %{sample: %{"lost" => 4}, story: true, canvas: false}},
    {"feed_restart", %{sample: %{}, story: true, canvas: false}}
  ]

  # tick-produced: Reducer.tick writes the row directly (no fold clause)
  @tick_synthetic ["stalled", "abandoned"]

  @doc "Wire kinds with metadata, in display order."
  def wire, do: @wire

  @doc "Synthetic kinds the feed folds like wire events (feed_gap/feed_restart)."
  def folded_synthetic, do: @folded_synthetic

  @doc "Synthetic kinds produced by the tick pass (no fold clause)."
  def tick_synthetic, do: @tick_synthetic

  @doc """
  The Events-page filter list: every kind that can appear as a story row —
  story-visible wire kinds, then tick synthetics, then folded synthetics.
  """
  def filter_kinds do
    for({k, %{story: true}} <- @wire, do: k) ++
      @tick_synthetic ++ for({k, _} <- @folded_synthetic, do: k)
  end

  @doc "Every kind pipeline.js must mention (case arm or intake normalization)."
  def canvas_kinds do
    for {k, %{canvas: true}} <- @wire, do: k
  end
end
