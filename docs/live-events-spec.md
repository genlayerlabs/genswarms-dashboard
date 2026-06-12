# Live Events Experience — implementation spec

Status: APPROVED DESIGN, not yet implemented.
Replaces the wingston-side prototype (`prototype/dashboard/` in wingstonrallybot) by
porting its three parity-proven views into this repo. Companion producer-side doc:
wingstonrallybot `docs/display-event-feed-plan.md` (Proposal A — built and live).

---

## 1. Goal

Make the dashboard tell the **exact live story of every request** — who asked, which
agent claimed it, what it waited on, when the reply landed — with **zero log-parsing
heuristics**. The source is wingston's display event feed: objects emit exact facts at
the moment they own them, so the dashboard renders truth instead of guessing from log
adjacency (the log-driven prototype misattributed requests on its first real
multi-user burst; the events-driven twin was 7/7 correct).

Three proven views move in:

1. **In-flight requests** — who is waiting right now, on what, for how long.
2. **Story feed** — human-readable lifecycle rows (`▶ open → ⟳ claim → ⏸ wait → ✓ replied in 9.0s`).
3. **Pipeline canvas** — animated topology with causal playback (replaces the cytoscape graph).

Plus the derived layer they enable: KPIs (reply latency percentiles, first-feedback
time), an issues feed, and per-session request timelines.

---

## 2. The producer contract (already live, other repo)

Wingston objects emit on a single telemetry wire — `[:wingston, :display]`, kind as
data — collected by `Wingston.EventFeed` (GenServer single-writer → **gapless seq**,
protected ETS ring of 4096, cursor reads via `since(seq, limit)`).

Event registry v1 (authoritative copy: `Wingston.EventFeed` moduledoc):

| kind            | fields              | meaning                                        |
|-----------------|---------------------|------------------------------------------------|
| `request_open`  | cid                 | ingress accepted a user message                |
| `routed`        | cid, slot           | task delivered to an agent slot (claim/queue)  |
| `typing`        | cid                 | typing indicator triggered                     |
| `spawn_start`   | cid, slot           | agent backend starting (docker)                |
| `teardown`      | cid, slot           | slot torn down                                 |
| `inbox_full`    | cid, slot           | turn rejected, user notified busy              |
| `ask`           | from                | agent asked the policy object                  |
| `browse_dispatch` | agent, url \| act | browse call dispatched                         |
| `browse_done`   | agent, verdict      | browse finished (any verdict)                  |
| `progress_sent` | cid                 | interim status posted to the user              |
| `reply_sent`    | cid, ok, threaded   | THE reply delivered (ok: true/false)           |
| `reply_failed`  | from                | reply dropped (unresolvable target)            |
| `proactive_sent`| cid                 | proactive/push message sent                    |
| `compaction`    | cid                 | agent context compacting (☕ note sent)        |
| `inbox_dropped` | agent, count        | backend died with queued tasks stranded        |

Every event also carries `seq` (monotonic, gapless) and `ts` (unix seconds, float).

**Compatibility rule (binding on every consumer in this repo):** kinds are additive.
An unknown kind MUST render as a generic story row and MUST NOT crash or stall any
reducer, view, or hook. Missing optional fields likewise.

---

## 3. Architecture

```
   wingston BEAM (orchestrator host)              dashboard container (this repo, frontend/)
   ───────────────────────────────              ──────────────────────────────────────────
   objects ──:telemetry──▶ Wingston.EventFeed     SubzeroSwarmDashboard.EventsFeed (poller)
                              ▲ events_since/2        │  cursor poll, default 700ms
   GenswarmsDashboard.Plug ───┘                       │  GET /api/swarms/:s/events/feed?since=&limit=
     (backend/, runs in-BEAM,  ◀──────HTTP────────────┘  (token-gated like every route)
      host injects :events_source)                     │
                                            broadcasts on PubSub topic "events":
                                              {:display_event, ev}   per event (canvas animation)
                                              {:story, summary}      per batch (folded state)
                                                       │
                                  SubzeroSwarmDashboard.Story.Reducer (PURE fold)
                                                       │
                                  DashHooks assigns @story  →  LiveViews render
```

Ownership split — same philosophy as `DataSource`:

| Knows…                          | Lives in        | Module |
|---------------------------------|-----------------|--------|
| how facts are produced          | wingston        | `Wingston.EventFeed` (exists) |
| how to read them, generically   | `backend/`      | `EventsSource` behaviour + one route (passthrough, kind-agnostic) |
| what kinds MEAN, lifecycle fold | `frontend/`     | `Story.Reducer` (pure, unit-tested) |
| how to draw them                | `frontend/`     | LiveViews + `pipeline.js` hook |

The backend stays app-agnostic: it relays `{events, seq}` verbatim and never
interprets a kind. All wingston-specific vocabulary lives in the frontend fold and
the pipeline layout config.

---

## 4. Backend changes (`backend/`)

### 4.1 `GenswarmsDashboard.EventsSource` (new behaviour)

Mirror of `DataSource` — host-injected, optional:

```elixir
defmodule GenswarmsDashboard.EventsSource do
  @moduledoc "Cursor-read of the host's display event feed. Implemented by the host app."

  @doc """
  Events with seq > since, oldest first, plus the cursor to poll from next.
  Seqs are expected gapless per feed instance: a gap observed by a consumer means
  ring pruning (consumer should resync), a cursor REGRESSION means the feed
  restarted (consumer should re-baseline).
  """
  @callback events_since(since :: non_neg_integer(), limit :: pos_integer()) ::
              %{events: [map()], seq: non_neg_integer()} | :unavailable
end
```

### 4.2 `start/1` + Config

New optional opt `:events_source` (module or nil), stored in `Config` alongside
`:data_source`. Nil ⇒ the route answers `source: "unavailable"` (fail-soft, same
posture as history/logs/skills).

### 4.3 Route (Plug)

```
GET /api/swarms/:name/events/feed?since=N&limit=M
  → 200 {"events": [...], "seq": cursor, "source": "feed"}
  → 200 {"events": [],    "seq": 0,      "source": "unavailable"}   (no source / source error)
```

- Sits behind the existing `:auth` plug — token or loopback, nothing new.
- `since` defaults 0, `limit` defaults 500, both via the existing `to_int/2`
  (cap 10_000); the host impl may clamp tighter.
- Distinct path from the existing `GET …/events` (engine LogStore), which is KEPT
  unchanged — it remains the "engine raw" surface (§5.6). Plug.Router matches whole
  segments, so order is irrelevant.
- Wrap the source call in try/rescue/catch-exit → `"unavailable"` (a feed crash must
  not 500 the dashboard).

### 4.4 Contract

- Add the route + envelope to the golden contract test (shape, source labels,
  passthrough of unknown event fields) and to `backend/README.md`'s pinned-contract
  table.
- Plug tests: auth applies; no source configured; source raising; limit clamping.

---

## 5. Frontend changes (`frontend/`)

### 5.1 `SwarmClient.events_feed/3` (new callback)

```elixir
@callback events_feed(swarm :: String.t(), since :: non_neg_integer(), limit :: pos_integer()) ::
            {:ok, map()} | {:error, term()}
```

Http impl via Req like the rest; Mox in test.

### 5.2 `SubzeroSwarmDashboard.EventsFeed` (new GenServer)

Sibling of `SwarmFeed`, supervised next to it, disabled in test via the existing
`:start_feed` flag. Behavior (port of the prototype's `tail_loop`, parity-proven):

- Poll every `events_poll_ms` (config, default **700ms**).
- **First successful poll baselines the cursor** (`since=0`, keep `seq`, discard the
  ring's history — no replay of pre-boot events on dashboard restart).
- Each batch: fold every event through `Story.Reducer`, then broadcast on PubSub
  topic `"events"`:
  - `{:display_event, ev}` per event — arrival-ordered, for the canvas hook;
  - `{:story, summary}` once per non-empty batch (and at most ~1/poll) — the folded
    snapshot every page renders from.
- **Gap** (first event seq > cursor+1): ring pruned while we lagged — fold a
  synthetic `feed_gap` issue (lost count) and continue.
  **Regression** (returned seq < cursor): feed restarted — re-baseline, reset
  since-boot state, note it in the story.
- `source: "unavailable"` or HTTP error: broadcast `{:story, summary}` with
  `feed_status: :unavailable`; keep polling. Pages degrade to snapshot-only (§9).

### 5.3 `SubzeroSwarmDashboard.Story` (new, the heart)

Two modules, **pure** and unit-tested — this is the direct port of the prototype's
events reducer (`broker_events.py`), the part that won the parity test:

- `Story.State` — struct: episodes (by cid: opened_at, agent, count, first_sent,
  closed verdict+duration), agent slots (state: idle/thinking/waiting-on-X/spawning,
  queue depth, since), story ring (last N lifecycle rows), issues ring (24h),
  counters (since baseline: replies, reply durations for p50/p95, first-feedback
  durations, browse ok/total, asks, compactions, inbox_full, …).
- `Story.Reducer.apply(state, event) :: state` — total function; unknown kind ⇒
  generic story row, state otherwise untouched.

Kind → fold (lifecycle vocabulary identical to the prototype):

| kind            | story row                          | state effect |
|-----------------|------------------------------------|--------------|
| `request_open`  | `▶ @user request open`             | open episode, or count++ on the open one |
| `routed`        | `⟳ agent_N claims cid` / `queued`  | attach agent; idle ⇒ thinking, busy ⇒ queue+1 |
| `spawn_start`   | `⚙ agent_N spawning`               | spawning state |
| `browse_dispatch` | `⏸ agent_N waiting on browse`    | waiting(browse), stamp since |
| `browse_done`   | `▶ resumed — browse ok in 3.9s`    | thinking; verdict ∉ {ok-ish} ⇒ issue |
| `ask`           | `⇄ agent_N asked policy`           | thinking refresh |
| `progress_sent` | `✉ progress to @user`              | stamp first_sent |
| `reply_sent` ok | `✓ @user replied in 9.0s`          | close episode (exact), agent queue-1 or idle |
| `reply_sent` !ok| `⚠ delivery failed`                | issue |
| `reply_failed`  | `⚠ reply dropped (no target)`      | issue |
| `inbox_full`    | `⚠ rejected — inbox full`          | issue |
| `inbox_dropped` | `⚠ backend died, N tasks lost`     | issue, slot idle |
| `teardown`      | `✖ agent_N torn down`              | slot idle |
| `compaction`    | `☕ compacting context`             | story note |
| `typing` / `proactive_sent` | (canvas packet only)   | — |
| unknown         | generic `· kind …` row             | — |

**Issues** (one classifier, used by the Overview feed, Events "issues only" filter,
and Sessions badges): `reply_failed`, `reply_sent ok:false`, `inbox_full`,
`inbox_dropped`, `browse_done` with a failure verdict, `feed_gap`, and the derived
**stalled episode** (open with no close past `stall_after_ms`, default 3 min).

**KPIs** (from closes): replies, reply p50/p95, first-feedback p50
(open→first progress/reply), browse ok-rate, asks, compactions. v1 counters are
**since baseline** and labeled so (`since 09:12`) — honest, not fake-daily. Durable
"today" overlays arrive via the snapshot `extensions` block (§6.3), preferred when
present.

### 5.4 DashHooks: `@story`

Extend the existing `on_mount` hook — exactly the `@snapshot` pattern: subscribe to
`"events"`, centralize `{:story, summary}` into `assign(:story, …)`, let
`{:display_event, _}` fall through (`:cont`) for pages that consume raw events
(Topology). The shared layout header gains the feed liveness chip
(`feed 2s ago` / amber when `feed_status != :ok` or last event stale) rendered from
`@story` — the dashboard's dead-man switch.

### 5.5 Pipeline canvas (`assets/js/hooks/pipeline.js`, new) — replaces cytoscape

TopologyLive is rewritten around the prototype's proven canvas:

- **Layout**: fixed pipeline lanes — `telegram → ingress → agent column → sender →
  telegram` with services (rally, policy, browse, web) above and bookkeeping
  (roster, commands, cron, metrics) below; reply arcs curve back. The lane/node map
  is **config, not code**: `config :subzero_swarm_dashboard, :pipeline_layout`
  (wingston's map is the default), pushed to the hook once via
  `push_event("pipeline:init", layout)`. Agent nodes are dynamic (from `@snapshot`
  pool + events).
- **Events**: TopologyLive pushes each `{:display_event, ev}` via
  `push_event("pipeline:event", ev)`. The hook owns display timing:
  **causal playback ON by default** — a client-side queue plays packets in causal
  order (~1.1s flight, 200ms stagger, same-origin siblings fork-fan-out together),
  and node state changes apply when their packet lands, so the picture never shows
  an effect before its cause. Controls: pause / step / causal toggle / chatter
  toggle (background rally↔policy heartbeat packets).
- **States**: thinking ring (●), waiting ring + elapsed + amber dashed edge to the
  waited-on service (◐), spawning (◌), queue badge (⁺¹), green reply arcs, red
  error flashes, ☕ on compaction.
- **Debug rig**: ported, gated by `?debug=1` (handle_params → `data-debug` on the
  hook el): raw event/op trace ring + pause-step + copy-to-clipboard. Invisible
  otherwise.
- Below the canvas: the in-flight strip (true state, instant — from `@story`, not
  the paced animation) and the node table fallback (kept).
- **cytoscape + fcose vendor files and the old `topology.js` hook are deleted**
  (`assets/vendor` imports, `priv/static/vendor` copies, app.js wiring).
- `phx-update="ignore"` + unique id, per LiveView hook rules.

### 5.6 Page-by-page (target mocks)

Common header: nav + `feed 2s ago` liveness chip (§5.4).

**Overview — "is everything OK right now, and is anyone waiting?"**

```
┌─ IN FLIGHT (2) ──────────────────────────────────────────────────────────────┐
│ @albert        agent_0   waiting on browse          12.4s ▓▓▓▓▓▓░░  [session] │
│ @maria ·+1     agent_1   thinking (1 queued)         4.1s ▓▓░░░░░░  [session] │
├─ AGENTS ─────────────────────────────────────────────────────────────────────┤
│ agent_0 ◐ waiting browse 12s │ agent_1 ● thinking 4s │ agent_2 ○ idle 10m    │
│ pool 3/2048 leased · 4 spawns (avg backend-up 1.4s)                          │
├─ TODAY (since 09:12) ────────────────────────────────────────────────────────┤
│ replies 41   p50 9.2s   p95 51s   first-feedback p50 3.1s                    │
│ failures 0   inbox_full 1   stalled 0   compactions 3   browse 84% ok        │
├─ ISSUES (24h) ───────────────────────────────────────────────────────────────┤
│ 14:19  tg:739…   stalled — no reply                                [events →]│
│ 12:25  agent_0   browse not_allowed (allowlist)                    [events →]│
│ 11:16  tg:568…   inbox_full → user notified                        [events →]│
└──────────────────────────────────────────────────────────────────────────────┘
```

Sources: `@story` (in-flight, agents, KPIs, issues) + `@snapshot` (pool, status,
warnings — existing cards stay below). Issue rows deep-link to `/events?cid=…`.

**Topology — "watch it think; where is the flow stuck?"** — §5.5 canvas, controls
(`⏸ pause · step › · ☑ causal · ☐ chatter`), legend, in-flight strip, table fallback.

**Sessions** — existing list + per-row issue badges (24h, from `@story`) and an
audience footer (`reachable 214 DMs · push-eligible 198 …`) read from
`extensions["audience"]` when present (§6.3).

**Session detail** — existing transcript/skills/logs + new **REQUESTS** section:
`@story` episodes filtered to this cid, newest first, honesty-labeled:

```
14:26:00  open → claim 1.0s → ask policy → ✓ replied 9.0s   (threaded)
14:25:38  open → claim 1.2s → browse ok 3.9s → ✓ replied 16.0s
   (requests observed since 09:12)
```

**Events — story-first.** View toggle `◉ story ○ engine raw`:
- *story*: the `@story` ring rendered as lifecycle rows (LiveView stream), filters:
  kind, cid, agent, **issues only**; rows link to session/topology.
- *engine raw*: the EXISTING LogStore table + its server-side filters, demoted
  behind the toggle — code kept as the current function components.

```
view ◉ story ○ engine-raw   kind [all▾]  cid [____]  agent [all▾]  ☐ issues only
14:26:10  ✓  @568…    replied in 9.0s
14:26:01  ⟳  agent_0  claims tg:568…
14:25:49  ▶  agent_0  ⟵ browse ok in 3.9s
14:25:45  ⏸  agent_0  waiting on browse
14:25:38  ▶  @568…    request open
```

**Usage** — existing router/LLM cards + a WINGSTON row: replies / browse ok-rate /
asks / compactions (from `@story` counters; durable daily values from
`extensions["metrics_today"]` when present).

**Logs** — unchanged.

---

## 6. Host-side changes (wingstonrallybot repo — sequenced with the PRs)

1. **`Wingston.EventsSource`** (new object, ~10 lines): implements
   `GenswarmsDashboard.EventsSource` by delegating to `Wingston.EventFeed.since/2`
   (clamping limit to the feed's own 2000). `run_live.exs` passes
   `events_source: Wingston.EventsSource` to `GenswarmsDashboard.start/1`.
   Submodule bump after backend PR merges.
2. **Retirement** (after the frontend pages are live and verified):
   `Wingston.EventFeedPlug` + its Bandit listener on :4011 (`EVENTS_PORT`), the
   harness's plug-route checks, the whole `prototype/` directory (`broker.py`,
   `broker_events.py`). `Wingston.EventFeed` itself STAYS — it is the source.
3. **Durable overlays** (optional, last): `Wingston.DashboardSource.snapshot/1`
   extensions gain `"metrics_today"` (replies/failures/inbox_full… straight from
   metrics_daily — already durable) and `"audience"` (roster counts). The
   `extensions` block is the designed seam for exactly this — no backend change.

---

## 7. Delivery plan (reviewable slices, in order)

| # | Repo · scope | Contents |
|---|--------------|----------|
| 1 | dashboard PR · `backend/` | `EventsSource` behaviour, Config + `start/1` opt, `/events/feed` route, golden contract + plug tests, README contract row |
| 2 | wingston commit | `Wingston.EventsSource` + run_live wiring + submodule bump; verify `curl :4001/api/swarms/wingston/events/feed` live |
| 3 | dashboard PR · `frontend/` foundation | `SwarmClient.events_feed`, `EventsFeed` poller, `Story.State`+`Story.Reducer` with the full unit-test port of the parity scenarios, DashHooks `@story`, header liveness chip. No page rework yet — invisible except the chip |
| 4 | dashboard PR · Topology | `pipeline.js` + TopologyLive rewrite, causal default, `?debug=1` rig, cytoscape/fcose deletion |
| 5 | dashboard PR · Overview + Events | in-flight/agents/KPI/issues panels; story-first Events with raw toggle |
| 6 | dashboard PR · Sessions/Detail/Usage | issue badges, REQUESTS timeline, wingston usage row, audience footer (renders only when extensions present) |
| 7 | wingston commit | extensions overlays (`metrics_today`, `audience`) in DashboardSource |
| 8 | wingston commit | retirement: EventFeedPlug + :4011 + `prototype/` |

Each dashboard PR: `mix precommit` green in the touched app; golden-contract changes
only ever deliberate. Steps 2/7/8 follow the standing wingston deploy flow.

---

## 8. Testing

- **Backend**: golden contract for `/events/feed` (shape, both source labels,
  unknown-field passthrough); auth; raising source → unavailable.
- **Reducer**: pure unit tests replaying the recorded real traces that drove the
  prototype (single request, browse wait, queued follow-up + count merge, multi-user
  burst attribution, inbox_full, compaction mid-wait, unknown kind, feed_gap,
  baseline reset) — assert episodes, agent states, KPIs, issues.
- **EventsFeed**: Mox-driven — baseline-on-first-poll, cursor advance, gap → issue,
  regression → re-baseline, unavailable → degraded status. `start_supervised!`,
  no sleeps (drain via `:sys.get_state`).
- **LiveViews**: element-ID assertions — Overview in-flight rows render from a
  pushed `{:story, …}`; Events toggle swaps story/raw; Topology mounts the hook el
  with `phx-update="ignore"` and pushes `pipeline:init`; SessionDetail REQUESTS
  section filters by cid.

---

## 9. Failure modes & degradation

| Failure | Behavior |
|---|---|
| feed route unavailable (old backend, no events_source) | header chip amber `feed unavailable`; story panels show a one-line explainer; snapshot-driven content (sessions, pool, transcripts, raw events, usage) fully functional |
| feed gap (ring pruned while lagging) | synthetic issue row with lost-count; counters keep going (marked) |
| feed cursor regression (bot restart) | re-baseline + reset since-baseline counters, story note |
| dashboard restart | counters restart at the new baseline — always labeled `since HH:MM`, never presented as a full day (until `metrics_today` overlay exists) |
| event burst | reducer is O(1)/event; canvas paces display client-side; story ring + LiveView streams bound memory |

---

## 10. Non-goals / parked

- **Durable latency percentiles across restarts** — needs a wingston-side daily
  aggregate; `extensions.metrics_today` covers counts first; percentiles can join
  that block later.
- **Engine-truth thinking pulse & queue depth** (turn-complete / queued-dispatch
  debug lines — "Proposal C", genswarms upstream): the reducer infers thinking
  conservatively; states it cannot know are simply not claimed.
- **Multi-swarm**, write paths (the dashboard stays read-only), WS push for the
  feed (cursor polling won the simplicity trade: gap detection + resync for free,
  proven feel at 700ms).
