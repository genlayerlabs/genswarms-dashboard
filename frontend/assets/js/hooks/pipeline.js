// Pipeline canvas — the events-driven topology (spec §5.5), a port of the
// parity-proven prototype canvas (wingstonrallybot prototype/dashboard/broker.py,
// kind→op mapping from broker_events.py reduce()). The LiveView pushes the lane
// layout once ("pipeline:init"), the snapshot's agent slots ("pipeline:agents"),
// and every raw display event ("pipeline:event"); this hook owns ALL display state
// and timing: the kind → packet/state mapping, causal playback (ON by default —
// node state changes apply when their packet LANDS, so the picture never shows an
// effect before its cause), pause/step, the chatter toggle, and the ?debug=1 trace
// rig. Colors come from the theme's CSS variables (success/warning/error/info/
// primary + base-content alphas), so light and dark both render correctly.

import * as jdenticon from "../../vendor/jdenticon"

const FLIGHT = 1100 // packet flight time (ms)
const STAGGER = 200 // launch stagger when flushing a backlog (ms)
// turn-end is invisible to the feed (no engine turn-complete event), so a node's
// claimed activity DECAYS when it stops producing events — thinking quickly (a
// finished turn), waiting slowly (a lost completion). Mirrors Story.Reducer so the
// canvas and the in-flight strip below it never disagree about a stale agent.
const THINK_DECAY = 60 // s of silence before a thinking node falls idle
const WAIT_DECAY = 300 // s before a waiting node does
const TAU = Math.PI * 2
const MONO = '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'

export const Pipeline = {
  mounted() {
    // read AT MOUNT: the el is phx-update="ignore", later attr changes never land
    this.debug = this.el.dataset.debug === "1"
    this.el.innerHTML = `
      <canvas class="absolute inset-0 w-full h-full"></canvas>
      <div data-role="ctl" class="absolute top-2 right-2 z-10 flex items-center gap-2 text-xs">
        <button type="button" data-role="pause" class="btn btn-xs">⏸ pause</button>
        <button type="button" data-role="step" class="btn btn-xs" disabled>step ›</button>
        <label class="flex items-center gap-1 cursor-pointer opacity-80">
          <input type="checkbox" data-role="causal" class="checkbox checkbox-xs" checked> causal
        </label>
        <label class="flex items-center gap-1 cursor-pointer opacity-80">
          <input type="checkbox" data-role="chatter" class="checkbox checkbox-xs"> chatter
        </label>
        <label class="flex items-center gap-1 cursor-pointer opacity-80">
          <input type="checkbox" data-role="rig" class="checkbox checkbox-xs" ${this.debug ? "checked" : ""}> rig
        </label>
        <span data-role="pcount" class="tnum text-warning"></span>
      </div>
      <div data-role="dbg" class="absolute left-2 top-2 bottom-2 w-96 z-10 hidden flex-col gap-2 overflow-hidden rounded-box border border-base-300 bg-base-100/90 p-2">
        <div class="flex justify-end shrink-0">
          <button type="button" data-role="copy" class="btn btn-xs">⧉ copy</button>
        </div>
        <pre data-role="dbgstate" class="m-0 font-mono text-[10px] leading-relaxed whitespace-pre-wrap break-all shrink-0 border-b border-base-300 pb-2"></pre>
        <pre data-role="dbglog" class="m-0 font-mono text-[10px] leading-relaxed whitespace-pre-wrap break-all opacity-70 overflow-auto flex-1"></pre>
      </div>`
    this.cv = this.el.querySelector("canvas")
    this.g = this.cv.getContext("2d")

    this.LAYOUT = null //  pipeline:init payload (lanes, chatter set, return arcs)
    this.FIXED = new Set() // names with a fixed lane position
    this.BG = new Set() //   chatter nodes (mutual traffic = background noise)
    this.AGENTS = new Set() // dynamic agent slots (snapshot pool + events)
    this.HANDLES = {} //     slot → avatar seed (leased slots only)
    this.AVATARS = {} //     avatar seed → offscreen canvas (generated once, cached)
    this.EXTRAS = new Set() // unknown non-agent endpoints → right-edge stack
    this.POS = {} //         name → {x, y, r, kind}
    this.AG = {} //          name → {state, waitOn, since, queue}
    this.CID = {} //         open cid → owning slot (set on routed, cleared on reply)
    this.EDGES = new Map() // "a|b" → recent-traffic heat
    this.PACKETS = []
    this.LANDS = [] //       scheduled state changes {at, fn} (apply on packet land)
    this.FLASH = {} //       name → error-flash deadline (performance.now ms)
    this.BADGE = {} //       name → {glyph, until} (☕ on compaction)
    this.PENDING = [] //     events not yet played (the causal queue)
    this.OPQ = [] //         ops of the event currently being played
    this.DBG = []
    this.skew = 0 //         Date.now()/1000 - newest event ts (display ages only)
    this.spawnCursor = 0
    this.lastPkt = null
    this.paused = false
    this.causal = true
    this.chatter = false

    this.q("pause").addEventListener("click", () => this.setPaused(!this.paused))
    this.q("step").addEventListener("click", () => this.stepOne())
    this.q("causal").addEventListener("change", (e) => {
      this.causal = e.target.checked
      if (!this.causal && !this.paused) this.flushQueue()
      this.dbg(this.causal ? "— CAUSAL mode on —" : "— CAUSAL mode off (firehose) —")
    })
    this.q("chatter").addEventListener("change", (e) => (this.chatter = e.target.checked))
    this.q("rig").addEventListener("change", (e) => this.setDebug(e.target.checked))
    this.q("copy").addEventListener("click", () => this.copyDbg())

    // canvas click → shared inspector (same phx-click="inspect" contract as
    // the node table below the canvas). POS is CSS-pixel space (layout() sizes
    // the canvas from clientWidth/Height), so offsetX/Y need no scaling.
    this.SESSIONS = {}
    this.SESSION_LABELS = {}
    this.cv.addEventListener("click", (e) => {
      const hit = this.agentAt(e.offsetX, e.offsetY)
      if (hit && this.SESSIONS[hit]) this.pushEvent("inspect", {session_id: this.SESSIONS[hit]})
    })
    this.cv.addEventListener("mousemove", (e) => {
      const hit = this.agentAt(e.offsetX, e.offsetY)
      this.cv.style.cursor = hit && this.SESSIONS[hit] ? "pointer" : ""
    })

    this.handleEvent("pipeline:init", (layout) => {
      this.LAYOUT = layout
      this.FIXED = new Set((layout.nodes || []).map((n) => n.name))
      this.BG = new Set(layout.chatter || [])
      this.refreshTheme()
      this.layout()
    })
    // snapshot wins existence: slots appear before their first event (additive —
    // a torn-down slot stays drawn idle rather than flickering between snapshots).
    // `handles` maps a leased slot to its avatar seed (the telegram handle) —
    // the node is labelled "agent_15" + the session id it serves and wears a
    // generated avatar. `sessions` maps the slot to the session id it serves
    // (canvas click→inspect target); `session_labels` is the drawn sub-line and
    // may be redacted independently. All maps are replaced wholesale so a
    // released slot drops its avatar + session on the next snapshot.
    this.handleEvent("pipeline:agents", ({agents, handles, sessions, session_labels}) => {
      this.HANDLES = handles || {}
      this.SESSIONS = sessions || {}
      this.SESSION_LABELS = session_labels || sessions || {}
      let changed = false
      for (const name of agents || []) {
        if (!this.FIXED.has(name) && !this.AGENTS.has(name)) {
          this.AGENTS.add(name)
          changed = true
        }
      }
      if (changed) this.layout()
    })
    this.handleEvent("pipeline:event", (ev) => this.intake(ev))

    this.ro = new ResizeObserver(() => this.layout())
    this.ro.observe(this.el)
    this.refreshTheme()
    this.pumpTimer = setInterval(() => this.pump(), 80)
    this.decayTimer = setInterval(() => {
      this.decayEdges()
      this.decayAgents() // stale thinking/waiting → idle (no turn-end event exists)
      this.refreshTheme() // tracks live theme switches; cheap at 1Hz
    }, 1000)
    if (this.debug) this.setDebug(true)
    this.raf = requestAnimationFrame(() => this.draw())
  },

  // the trace rig: ?debug=1 opens it at mount; the "rig" control toggles it live
  setDebug(on) {
    this.debug = on
    const panel = this.q("dbg")
    panel.classList.toggle("hidden", !on)
    panel.classList.toggle("flex", on)
    if (on && !this.dbgTimer) this.dbgTimer = setInterval(() => this.renderDbg(), 500)
    if (!on && this.dbgTimer) {
      clearInterval(this.dbgTimer)
      this.dbgTimer = null
    }
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    clearInterval(this.pumpTimer)
    clearInterval(this.decayTimer)
    if (this.dbgTimer) clearInterval(this.dbgTimer)
    if (this.ro) this.ro.disconnect()
  },

  q(role) {
    return this.el.querySelector(`[data-role="${role}"]`)
  },

  // ── event intake + causal pump ───────────────────────────────────────────────
  // One code path: stepOne plays exactly one op. Manual stepping (paused) and the
  // causal scheduler both drive it, so ordering is always the feed's seq order.
  intake(ev) {
    // browser_* are the wire names since the browse→browser package rename;
    // normalize LEGACY browse_* at ingress (an old host still emitting the
    // original vocabulary keeps animating) — mirror of the Elixir reducer's
    // fold("browse_*") delegation.
    if (ev.kind === "browse_dispatch") ev = {...ev, kind: "browser_dispatch"}
    if (ev.kind === "browse_done") ev = {...ev, kind: "browser_done"}
    if (typeof ev.ts === "number") this.skew = Date.now() / 1000 - ev.ts
    if (this.paused || this.causal) {
      this.PENDING.push(ev)
      if (this.PENDING.length > 400) this.PENDING.shift()
    } else {
      this.playEvent(ev, true)
    }
    this.updCtl()
  },

  playEvent(ev, immediate) {
    for (const op of this.reduce(ev)) this.execOp(op, immediate)
  },

  stepOne() {
    if (!this.OPQ.length) {
      const ev = this.PENDING.shift()
      if (!ev) {
        this.updCtl()
        return "empty"
      }
      this.OPQ.push(...this.reduce(ev))
    }
    const op = this.OPQ.shift()
    const spawned = op ? this.execOp(op, false) : false
    this.updCtl()
    return spawned ? "packet" : "event"
  },

  // launch the next packet only when the previous one is mostly across its edge
  // (cause lands before effect departs); tighten pacing as the queue grows and
  // fast-forward past 150 queued so the display never lags reality far
  pump() {
    if (this.paused || !this.causal) return
    const total = this.PENDING.length + this.OPQ.length
    if (total > 150) {
      this.dbg(`pump: ${total} queued — fast-forwarding`)
      this.flushQueue()
      return
    }
    const gapF = total > 50 ? 0.15 : total > 20 ? 0.45 : 0.75
    if (this.lastPkt && performance.now() - this.lastPkt.t0 < FLIGHT * gapF) return
    let guard = 25
    while (guard-- > 0) {
      const r = this.stepOne()
      if (r === "empty") break
      if (r === "packet") {
        // fork fan-out: same-origin siblings are parallel effects of one cause
        // (ingress fanning out, an agent's action batch) — launch them together
        const nx = this.nextOrigin()
        if (!(nx && this.lastPkt && nx === this.lastPkt.a)) break
      }
    }
  },

  // side-effect-free peek at the next op's packet origin (for fork detection)
  nextOrigin() {
    if (this.OPQ.length) return this.OPQ[0].a || null
    const ev = this.PENDING[0]
    if (!ev) return null
    switch (ev.kind) {
      case "request_open":
      case "typing":
      case "routed":
        return "ingress"
      case "ask":
        return ev.from || null
      case "browser_dispatch":
        return ev.agent || null
      case "browser_done":
        return (this.AG[ev.agent] || {}).waitOn === "browser" ? "web" : "browser"
      case "progress_sent":
      case "reply_sent":
        return (ev.cid && this.CID[ev.cid]) || "sender"
      case "proactive_sent":
        return "sender"
      default:
        return null
    }
  },

  flushQueue() {
    this.spawnCursor = 0
    while (this.OPQ.length) this.execOp(this.OPQ.shift(), true)
    while (this.PENDING.length) this.playEvent(this.PENDING.shift(), true)
    this.lastPkt = null
    this.updCtl()
  },

  setPaused(p) {
    this.paused = p
    this.dbg(p ? "— PAUSED —" : this.causal ? "— RESUMED (causal drain) —" : "— RESUMED (flushing queue) —")
    if (!p && !this.causal) this.flushQueue()
    this.updCtl()
  },

  updCtl() {
    const n = this.PENDING.length + this.OPQ.length
    this.q("pause").textContent = this.paused ? "▶ resume" : "⏸ pause"
    this.q("step").disabled = !this.paused
    this.q("pcount").textContent = n > 0 ? `${n} queued` : ""
  },

  // ── the reducer: one exact fact in → packets + state changes out ─────────────
  // Port of broker_events.py reduce(). State closures run when their packet lands
  // (or immediately when flushing) and read live agent state at that moment, so a
  // queued-vs-claims decision never acts on a state that hasn't landed yet.
  reduce(ev) {
    const kind = ev.kind
    const ts = typeof ev.ts === "number" ? ev.ts : this.feedNow()
    const slot = ev.slot
    const agent = ev.agent || ev.from
    this.dbg(`ev#${ev.seq || ""} ${kind} ${JSON.stringify(ev).slice(0, 120)}`)

    switch (kind) {
      case "request_open":
        return [{a: "ingress", b: "roster", kind: "msg"}]

      case "routed": {
        if (!slot) return []
        this.ensureAgent(slot)
        if (ev.cid) this.CID[ev.cid] = slot
        return [
          {
            a: "ingress",
            b: slot,
            kind: "msg",
            st: () => {
              const ag = this.ag(slot)
              if (ag.state !== "idle") ag.queue = Math.min(ag.queue + 1, 99)
              else this.setState(slot, "thinking", ts)
            },
          },
        ]
      }

      case "typing":
        return [{a: "ingress", b: "sender", kind: "msg"}]

      case "spawn_start":
        if (!slot) return []
        this.ensureAgent(slot)
        return [{st: () => this.setState(slot, "spawning", ts)}]

      case "teardown":
        if (!slot) return []
        this.ensureAgent(slot)
        return [
          {
            st: () => {
              this.setState(slot, "idle", ts)
              this.ag(slot).queue = 0
            },
          },
        ]

      case "inbox_full":
        if (slot) this.ensureAgent(slot)
        return [{flash: slot || "ingress"}]

      case "ask": {
        if (!agent) return []
        this.ensureNode(agent)
        return [
          {a: agent, b: "policy", kind: "msg", ask: true},
          {
            a: "policy",
            b: agent,
            kind: "reply",
            st: () => {
              const ag = this.AG[agent]
              if (!ag) return
              // already thinking: hold `since` (elapsed = whole turn) but refresh
              // the decay clock; otherwise a fresh thinking start
              if (ag.state === "thinking") this.touchAct(agent, ts)
              else this.setState(agent, "thinking", ts)
            },
          },
        ]
      }

      case "browser_dispatch": {
        if (!agent) return []
        this.ensureNode(agent)
        return [
          {a: agent, b: "browser", kind: "msg", st: () => this.setWaiting(agent, "browser", ts)},
          {a: "browser", b: "web", kind: "browse", v: "dispatched"},
        ]
      }

      case "browser_done": {
        if (!agent) return []
        this.ensureNode(agent)
        const v = ev.verdict || ""
        const resume = () => {
          const ag = this.AG[agent]
          if (ag && ag.state === "waiting" && ag.waitOn === "browser") this.setState(agent, "thinking", ts)
        }
        const ag = this.AG[agent]
        if (ag && ag.state === "waiting" && ag.waitOn === "browser") {
          // the reply travels web → browse → agent; the resume applies on arrival
          return [
            {a: "web", b: "browser", kind: "reply", v},
            {a: "browser", b: agent, kind: "reply", v, st: resume},
          ]
        }
        return [{a: "browser", b: agent, kind: "reply", v, st: resume}]
      }

      case "progress_sent": {
        const owner = ev.cid && this.CID[ev.cid]
        const ops = []
        if (owner) ops.push({a: owner, b: "sender", kind: "msg"})
        ops.push({a: "sender", b: "telegram", kind: "sent"})
        return ops
      }

      case "reply_sent": {
        const ok = ev.ok === true
        const owner = ev.cid && this.CID[ev.cid]
        if (ok && ev.cid) delete this.CID[ev.cid]
        const release = () => {
          const ag = owner && this.AG[owner]
          if (!ag) return
          if (ag.queue > 0) {
            ag.queue--
            this.setState(owner, "thinking", ts)
          } else {
            this.setState(owner, "idle", ts)
          }
        }
        const ops = []
        if (owner) ops.push({a: owner, b: "sender", kind: "msg", st: release})
        ops.push({a: "sender", b: "telegram", kind: "sent", v: ok ? "" : "failed"})
        if (!ok) ops.push({flash: "sender"})
        return ops
      }

      case "proactive_sent":
        return [{a: "sender", b: "telegram", kind: "sent"}]

      case "compaction": {
        const owner = ev.cid && this.CID[ev.cid]
        return owner ? [{badge: owner, glyph: "☕"}] : []
      }

      case "inbox_dropped":
        if (!agent) return []
        return [
          {
            st: () => {
              this.setState(agent, "idle", ts)
              this.ag(agent).queue = 0
            },
          },
          {flash: agent},
        ]

      case "reply_failed":
        return [{flash: "sender"}]

      // marked push (campaign/operator) attempted and failed non-403: the
      // send left for telegram and died — a failed sent edge + sender flash
      case "push_failed":
        return [
          {a: "sender", b: "telegram", kind: "sent", v: "failed"},
          {flash: "sender"},
        ]

      case "reply_suppressed": {
        // the spam-window guard chose silence — a 🤫 float, not a flash:
        // suppression is the guard working, not a failure
        const owner = ev.cid && this.CID[ev.cid]
        return [{badge: owner || "sender", glyph: "🤫"}]
      }

      case "llm_error": {
        // the agent's LLM turn failed — error flash where the turn was running
        const owner = agent || (ev.cid && this.CID[ev.cid])
        if (!owner || !this.AG[owner]) return []
        return [{flash: owner}, {badge: owner, glyph: "⚠"}]
      }

      case "llm_proxy_block": {
        // spending wall — ⛔ on the owning agent (there is no llm node in the
        // layout; the block lands where its effect is felt). llm_proxy_degraded
        // stays canvas-silent for the same no-geometry reason (registry: canvas
        // false) — it's an Issues-panel fact, not a pipeline one.
        const owner = agent || (ev.cid && this.CID[ev.cid])
        if (!owner || !this.AG[owner]) return []
        return [{flash: owner}, {badge: owner, glyph: "⛔"}]
      }

      case "job_run":
        // cron animates its own work at last: a quiet ✓ float per ok run,
        // an error flash + ⚠ when a job fails
        return ev.status === "ok"
          ? [{badge: "cron", glyph: "✓"}]
          : [{flash: "cron"}, {badge: "cron", glyph: "⚠"}]

      case "chatter": {
        // background bookkeeping traffic (rally↔policy sync, metrics bumps) —
        // the host emits these precisely so the chatter toggle has data; forced
        // bg regardless of endpoint sets, never part of user-flow causality
        if (!ev.from || !ev.to) return []
        return [{a: ev.from, b: ev.to, kind: "msg", bg: true}]
      }

      default:
        // kinds are additive (spec §2): unknown must not crash or stall playback
        return []
    }
  },

  // execute one op; returns true iff a foreground packet was spawned (the causal
  // pump gates only on those — chatter and pure state changes never block flow)
  execOp(op, immediate) {
    if (op.flash) this.FLASH[op.flash] = performance.now() + 1600
    if (op.badge) this.BADGE[op.badge] = {glyph: op.glyph, until: performance.now() + 5000}
    if (!op.a || !op.b) {
      if (op.st) op.st()
      return false
    }
    const bg = op.bg === true || this.isBg(op.a, op.b)
    const k = op.a + "|" + op.b
    this.EDGES.set(k, (this.EDGES.get(k) || 0) + (bg ? 0.2 : 1))
    if (bg) {
      // chatter: small dim dots when toggled on; never part of user-flow causality
      if (this.chatter && this.POS[op.a] && this.POS[op.b])
        this.PACKETS.push({a: op.a, b: op.b, t0: performance.now(), kind: op.kind, bg: true})
      if (op.st) op.st()
      this.dbg(`op ${this.short(op.a)}→${this.short(op.b)} :: bg`)
      return false
    }
    if (this.POS[op.a] && this.POS[op.b]) {
      const t0 = immediate ? this.staggeredT0() : performance.now()
      const pkt = {a: op.a, b: op.b, t0, kind: op.kind, v: op.v}
      this.PACKETS.push(pkt)
      this.lastPkt = pkt
      if (op.st) {
        if (immediate) op.st()
        else this.LANDS.push({at: t0 + FLIGHT, fn: op.st})
      }
      this.dbg(`op ${this.short(op.a)}→${this.short(op.b)} ${op.kind}${op.v ? " " + op.v : ""} :: pkt`)
      return true
    }
    if (op.st) op.st() // no node position yet — never lose the state change
    this.dbg(`op ${this.short(op.a)}→${this.short(op.b)} :: DROPPED (no node pos)`)
    return false
  },

  // flush-mode launches stagger so a drained backlog still reads as a sequence
  // (capped: sustained firehose traffic must not schedule ever further ahead)
  staggeredT0() {
    const now = performance.now()
    this.spawnCursor = Math.min(Math.max(now, this.spawnCursor + STAGGER), now + 2000)
    return this.spawnCursor
  },

  // ── node + agent state plumbing ──────────────────────────────────────────────
  ag(name) {
    return (
      this.AG[name] ||
      (this.AG[name] = {name, state: "idle", waitOn: null, since: 0, lastAct: 0, queue: 0})
    )
  },

  setState(name, state, ts) {
    const ag = this.ag(name)
    this.dbg(`STATE ${this.short(name)}: ${ag.state}${ag.waitOn ? "(" + ag.waitOn + ")" : ""} → ${state}`)
    ag.state = state
    ag.waitOn = null
    ag.since = ts
    ag.lastAct = ts
  },

  setWaiting(name, on, ts) {
    const ag = this.ag(name)
    this.dbg(`STATE ${this.short(name)}: ${ag.state} → waiting(${on})`)
    ag.state = "waiting"
    ag.waitOn = on
    ag.since = ts
    ag.lastAct = ts
  },

  // an agent that keeps thinking (e.g. a stream of asks) holds its `since` so the
  // displayed elapsed reflects the whole turn, but every event still refreshes
  // `lastAct` — the decay clock — so genuine work never decays, only silence does
  touchAct(name, ts) {
    this.ag(name).lastAct = ts
  },

  // no turn-complete event exists; stop claiming activity a node can't evidence.
  // Silent (no packet, no log spam) — we just drop the stale ring.
  decayAgents() {
    const snow = this.feedNow()
    for (const ag of Object.values(this.AG)) {
      if (ag.state === "thinking" && snow - ag.lastAct > THINK_DECAY) {
        ag.state = "idle"
        ag.waitOn = null
        ag.queue = 0
      } else if (ag.state === "waiting" && snow - ag.lastAct > WAIT_DECAY) {
        ag.state = "idle"
        ag.waitOn = null
        ag.queue = 0
      }
    }
  },

  ensureAgent(name) {
    if (this.FIXED.has(name) || this.AGENTS.has(name)) return
    this.AGENTS.add(name)
    this.layout()
  },

  // event endpoints: agent-looking names join the column, anything else stacks
  // on the right edge (a new wingston object shows up without a layout change)
  ensureNode(name) {
    if (this.FIXED.has(name) || this.AGENTS.has(name) || this.EXTRAS.has(name)) return
    if (/agent/.test(name)) {
      this.ensureAgent(name)
    } else {
      this.EXTRAS.add(name)
      this.layout()
    }
  },

  isBg(a, b) {
    return this.BG.has(a) && this.BG.has(b)
  },

  // ── geometry ─────────────────────────────────────────────────────────────────
  // nearest agent dot under the pointer (CSS px — same space as POS)
  agentAt(x, y) {
    for (const [name, p] of Object.entries(this.POS || {})) {
      if (p.kind !== "agent") continue
      if (Math.hypot(x - p.x, y - p.y) <= (p.r || 10) + 6) return name
    }
    return null
  },

  layout() {
    if (!this.LAYOUT) return
    const W = (this.cv.width = this.cv.clientWidth || this.el.clientWidth)
    const H = (this.cv.height = this.cv.clientHeight || this.el.clientHeight)
    this.POS = {}
    for (const n of this.LAYOUT.nodes || [])
      this.POS[n.name] = {x: n.x * W, y: n.y * H, r: n.r || 18, kind: n.kind || "obj"}
    let extra = 0
    for (const n of this.EXTRAS) this.POS[n] = {x: 0.9 * W, y: (0.74 - extra++ * 0.14) * H, r: 18, kind: "obj"}
    // Agents fill a CENTERED GRID, not one endless column: a single column is
    // clean at 16 slots and unreadable at 60. Rows are capped by a minimum
    // pixel pitch (dot + label air); overflow wraps into extra columns spread
    // around the column axis, column-major so numeric order reads top-down.
    const ags = [...this.AGENTS].sort((a, b) => this.agentOrder(a, b))
    const colX = this.LAYOUT.agent_column_x || 0.47
    const spanY = 0.66
    const minPitch = 44
    const maxRows = Math.max(1, Math.floor((spanY * H) / minPitch))
    const cols = Math.max(1, Math.ceil(ags.length / maxRows))
    const rows = Math.ceil(ags.length / cols)
    const gapY = rows > 1 ? Math.min(0.1 * H, (spanY * H) / (rows - 1)) : 0
    const colPitch = Math.min(120, (0.32 * W) / cols)
    const r = cols > 2 ? 11 : 13
    ags.forEach((n, i) => {
      const c = Math.floor(i / rows)
      const inCol = Math.min(rows, ags.length - c * rows)
      const y = 0.5 * H + ((i % rows) - (inCol - 1) / 2) * gapY
      const x = colX * W + (c - (cols - 1) / 2) * colPitch
      this.POS[n] = {x, y, r, kind: "agent"}
    })
  },

  // agent_2 before agent_10: compare trailing numbers when both have one
  agentOrder(a, b) {
    const na = parseInt((String(a).match(/(\d+)$/) || [])[1], 10)
    const nb = parseInt((String(b).match(/(\d+)$/) || [])[1], 10)
    if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb
    return a < b ? -1 : a > b ? 1 : 0
  },

  // reply legs curve back under the pipeline instead of cutting through it
  geom(a, b) {
    for (const arc of (this.LAYOUT && this.LAYOUT.return_arcs) || [])
      if (arc.from === a && arc.to === b) return {q: 1, cx: arc.cx * this.cv.width, cy: arc.cy * this.cv.height}
    return {q: 0}
  },

  pAt(A, B, gm, u) {
    if (!gm.q) return {x: A.x + (B.x - A.x) * u, y: A.y + (B.y - A.y) * u}
    const t = u
    const m = 1 - t
    return {x: m * m * A.x + 2 * m * t * gm.cx + t * t * B.x, y: m * m * A.y + 2 * m * t * gm.cy + t * t * B.y}
  },

  decayEdges() {
    this.EDGES.forEach((v, k) => {
      const n = v * 0.82
      n < 0.15 ? this.EDGES.delete(k) : this.EDGES.set(k, n)
    })
  },

  // ── theme ────────────────────────────────────────────────────────────────────
  // The canvas is ALWAYS the brand's dark terminal panel (the inset window on
  // genswarms.com's hero): warm black behind (.pipeline-terminal in app.css),
  // bone ink, ember = live. Page themes restyle the chrome AROUND the panel —
  // in-panel contrast stays constant and high in light and dark alike.
  refreshTheme() {
    this.C = {
      ink: "#EDE3CF", //     bone — labels, edges, idle bodies
      bg: "#191309", //      pill/badge fills on the panel
      ember: "#FF5A1F", //   the brand accent: traffic, thinking
      ok: "#62CD8E", //      replies / success verdicts
      warn: "#F2B244", //    waiting / queued / stalled
      err: "#F2604C", //     failures
      info: "#82B6E8", //    spawning / browse dispatch
      traffic: "#FF5A1F", // generic message packets (= ember)
    }
  },

  pktColor(p) {
    if (p.kind === "reply") return p.v === "render_failed" || p.v === "blocked" ? this.C.err : this.C.ok
    if (p.kind === "sent") return p.v === "failed" ? this.C.err : this.C.ok
    if (p.kind === "browse") return p.v === "blocked" ? this.C.err : this.C.info
    return this.C.traffic
  },

  // ── canvas draw loop ─────────────────────────────────────────────────────────
  draw() {
    const g = this.g
    const C = this.C
    g.clearRect(0, 0, this.cv.width, this.cv.height)
    const pnow = performance.now()
    const snow = this.feedNow()

    // causal contract: a state change becomes visible when its packet lands
    this.LANDS = this.LANDS.filter((l) => (l.at <= pnow ? (l.fn(), false) : true))

    // the static spine: telegram → … → sender (+ the return arc) as faint rails,
    // so the pipeline shape reads even when nothing is moving
    const railA = this.POS["telegram"]
    const railB = this.POS["sender"]
    if (railA && railB) {
      g.strokeStyle = C.ink
      g.globalAlpha = 0.08
      g.lineWidth = 2
      g.beginPath()
      g.moveTo(railA.x, railA.y)
      g.lineTo(railB.x, railB.y)
      g.stroke()
      const rgm = this.geom("sender", "telegram")
      if (rgm.q) {
        g.beginPath()
        g.moveTo(railB.x, railB.y)
        g.quadraticCurveTo(rgm.cx, rgm.cy, railA.x, railA.y)
        g.stroke()
      }
      g.globalAlpha = 1
    }

    // edges (chatter accumulates faintly; user traffic glows and cools)
    this.EDGES.forEach((h, k) => {
      const [a, b] = k.split("|")
      const A = this.POS[a]
      const B = this.POS[b]
      if (!A || !B) return
      const bg = this.isBg(a, b)
      const t = Math.min(h / 8, 1)
      const gm = this.geom(a, b)
      g.strokeStyle = C.ink
      g.globalAlpha = bg ? 0.07 + 0.09 * t : 0.26 + 0.38 * t
      g.lineWidth = bg ? 1 : 1.3 + t * 4
      g.beginPath()
      g.moveTo(A.x, A.y)
      gm.q ? g.quadraticCurveTo(gm.cx, gm.cy, B.x, B.y) : g.lineTo(B.x, B.y)
      g.stroke()
      if (!bg) {
        const ang = gm.q ? Math.atan2(B.y - gm.cy, B.x - gm.cx) : Math.atan2(B.y - A.y, B.x - A.x)
        const ex = B.x - Math.cos(ang) * (B.r + 2)
        const ey = B.y - Math.sin(ang) * (B.r + 2)
        g.fillStyle = C.ink
        g.beginPath()
        g.moveTo(ex, ey)
        g.lineTo(ex - Math.cos(ang - 0.4) * 7, ey - Math.sin(ang - 0.4) * 7)
        g.lineTo(ex - Math.cos(ang + 0.4) * 7, ey - Math.sin(ang + 0.4) * 7)
        g.fill()
      }
      g.globalAlpha = 1
    })

    // waiting edges: marching-ants from the agent to the service it waits on
    for (const [n, ag] of Object.entries(this.AG)) {
      if (ag.state !== "waiting" || !ag.waitOn) continue
      const A = this.POS[n]
      const B = this.POS[ag.waitOn]
      if (!A || !B) continue
      g.save()
      g.strokeStyle = C.warn
      g.lineWidth = 2.5
      g.setLineDash([8, 6])
      g.lineDashOffset = -(pnow / 40) % 14
      g.beginPath()
      g.moveTo(A.x, A.y)
      g.lineTo(B.x, B.y)
      g.stroke()
      g.restore()
      const mx = (A.x + B.x) / 2
      const my = (A.y + B.y) / 2
      const lbl = (snow - ag.since).toFixed(1) + "s"
      g.font = `600 11px ${MONO}`
      g.textAlign = "center"
      g.textBaseline = "middle"
      const w = g.measureText(lbl).width + 14
      g.fillStyle = C.bg
      g.globalAlpha = 0.92
      g.beginPath()
      g.roundRect(mx - w / 2, my - 10, w, 20, 6)
      g.fill()
      g.globalAlpha = 1
      g.fillStyle = C.warn
      g.fillText(lbl, mx, my)
    }

    // packets (comet trail, follow the edge geometry; chatter = single dim dot)
    this.PACKETS = this.PACKETS.filter((p) => pnow - p.t0 < FLIGHT)
    for (const p of this.PACKETS) {
      const A = this.POS[p.a]
      const B = this.POS[p.b]
      if (!A || !B) continue
      const u = (pnow - p.t0) / FLIGHT
      if (u < 0) continue
      const gm = this.geom(p.a, p.b)
      if (p.bg) {
        const pt = this.pAt(A, B, gm, u)
        g.globalAlpha = 0.45
        g.fillStyle = C.ink
        g.beginPath()
        g.arc(pt.x, pt.y, 2.4, 0, TAU)
        g.fill()
        g.globalAlpha = 1
        continue
      }
      const col = this.pktColor(p)
      g.save()
      g.shadowColor = col
      g.shadowBlur = 12
      for (let j = 0; j < 3; j++) {
        const ut = u - j * 0.055
        if (ut < 0) continue
        const pt = this.pAt(A, B, gm, ut)
        g.globalAlpha = [1, 0.5, 0.22][j]
        g.fillStyle = col
        g.beginPath()
        g.arc(pt.x, pt.y, [5, 3.6, 2.6][j], 0, TAU)
        g.fill()
      }
      g.restore()
      g.globalAlpha = 1
    }

    // objects an agent is currently waiting on get a working ring too
    const busyObjs = {}
    for (const ag of Object.values(this.AG)) if (ag.state === "waiting" && ag.waitOn) busyObjs[ag.waitOn] = ag

    for (const [n, P] of Object.entries(this.POS)) {
      const ag = P.kind === "agent" ? this.AG[n] : null
      const st = ag ? ag.state : null
      const objBusy = P.kind !== "agent" && busyObjs[n]
      // a leased slot: HANDLES[n] is its avatar seed, SESSIONS[n] the session id
      // or inspect token it serves. SESSION_LABELS[n] is the drawn sub-line. The
      // label is ALWAYS the slot id (agent_15) now; identity comes from the drawn
      // avatar + the session sub-line, not a "@handle" text label.
      const seed = P.kind === "agent" ? (this.HANDLES || {})[n] : null
      const sess = P.kind === "agent" ? (this.SESSIONS || {})[n] : null
      const sessLabel = P.kind === "agent" ? (this.SESSION_LABELS || {})[n] : null
      const label = this.short(n)
      // chatter nodes recede so the user-request lane owns the eye
      const dim = P.kind !== "agent" && this.BG.has(n) && !objBusy ? 0.5 : 1

      // box half-extents: agents are dots, ext endpoints small circles, objects
      // are chips SIZED TO THEIR LABEL (never clipped)
      let hw, hh
      if (P.kind === "agent") {
        hw = hh = P.r
      } else if (P.kind === "ext") {
        hw = hh = 15
      } else {
        g.font = `600 12px ${MONO}`
        hw = g.measureText(label).width / 2 + 11
        hh = 13
      }

      // body
      if (P.kind === "agent") {
        if (st === "thinking") {
          g.save()
          g.shadowColor = C.ember
          g.shadowBlur = 18
          g.fillStyle = C.ember
          g.beginPath()
          g.arc(P.x, P.y, P.r, 0, TAU)
          g.fill()
          g.restore()
        } else {
          g.fillStyle = st === "waiting" ? C.warn : st === "spawning" ? C.info : C.ink
          g.globalAlpha = st === "waiting" ? 0.9 : st === "spawning" ? 0.35 : 0.18
          g.beginPath()
          g.arc(P.x, P.y, P.r, 0, TAU)
          g.fill()
          g.globalAlpha = 1
          g.strokeStyle = C.ink
          g.globalAlpha = 0.4
          g.lineWidth = 1.5
          g.stroke()
          g.globalAlpha = 1
        }
        // leased slot → paint the seed's avatar inside the bubble (clipped round,
        // over the body). Free slots keep the plain dot.
        const av = this.avatarFor(seed)
        if (av) {
          g.save()
          g.beginPath()
          g.arc(P.x, P.y, P.r, 0, TAU)
          g.clip()
          g.drawImage(av, P.x - P.r, P.y - P.r, P.r * 2, P.r * 2)
          g.restore()
        }
      } else if (P.kind === "ext") {
        g.fillStyle = C.ink
        g.globalAlpha = 0.1 * dim
        g.beginPath()
        g.arc(P.x, P.y, hw, 0, TAU)
        g.fill()
        g.globalAlpha = 0.45 * dim
        g.strokeStyle = C.ink
        g.lineWidth = 1.5
        g.stroke()
        g.globalAlpha = 1
      } else {
        g.fillStyle = objBusy ? C.warn : C.ink
        g.globalAlpha = (objBusy ? 0.14 : 0.08) * dim
        g.beginPath()
        g.roundRect(P.x - hw, P.y - hh, hw * 2, hh * 2, 8)
        g.fill()
        g.globalAlpha = (objBusy ? 0.8 : 0.42) * dim
        g.strokeStyle = objBusy ? C.warn : C.ink
        g.lineWidth = 1.5
        g.stroke()
        g.globalAlpha = 1
      }

      // activity rings: ● pulsing thinking, ◐ steady waiting, ◌ spawning sweep
      if (st === "thinking" || objBusy) {
        g.strokeStyle = objBusy ? C.warn : C.ember
        g.lineWidth = 2.5
        g.beginPath()
        if (P.kind === "agent") g.arc(P.x, P.y, P.r + 4 + Math.sin(pnow / 170) * 1.8, 0, TAU)
        else g.roundRect(P.x - hw - 5, P.y - hh - 5, hw * 2 + 10, hh * 2 + 10, 11)
        g.stroke()
      } else if (st === "waiting") {
        g.strokeStyle = C.warn
        g.lineWidth = 3
        g.beginPath()
        g.arc(P.x, P.y, P.r + 4, 0, TAU)
        g.stroke()
      } else if (st === "spawning") {
        const a0 = (pnow / 260) % TAU
        g.strokeStyle = C.info
        g.lineWidth = 3
        g.lineCap = "round"
        g.beginPath()
        g.arc(P.x, P.y, P.r + 5, a0, a0 + 3.4)
        g.stroke()
        g.lineCap = "butt"
      }

      // red error flash (delivery failed, inbox full/dropped), fading out
      const fl = this.FLASH[n]
      if (fl && fl > pnow) {
        g.globalAlpha = Math.min((fl - pnow) / 1600, 1)
        g.strokeStyle = C.err
        g.lineWidth = 3
        g.beginPath()
        if (P.kind === "agent") g.arc(P.x, P.y, P.r + 7, 0, TAU)
        else g.roundRect(P.x - hw - 7, P.y - hh - 7, hw * 2 + 14, hh * 2 + 14, 12)
        g.stroke()
        g.globalAlpha = 1
      }

      // queue badge (⁺¹) — only while the agent is actually busy; a decayed-idle
      // node has no in-flight turn, so any residual queue is stale and must not paint
      if (ag && ag.queue > 0 && ag.state !== "idle") {
        g.fillStyle = C.warn
        g.beginPath()
        g.arc(P.x + hw + 5, P.y - hh - 3, 9, 0, TAU)
        g.fill()
        g.fillStyle = C.bg
        g.font = `700 10.5px ${MONO}`
        g.textAlign = "center"
        g.textBaseline = "middle"
        g.fillText(String(ag.queue), P.x + hw + 5, P.y - hh - 2.5)
      }

      // ☕ on compaction
      const bd = this.BADGE[n]
      if (bd && bd.until > pnow) {
        g.font = `14px ${MONO}`
        g.textAlign = "center"
        g.textBaseline = "middle"
        g.fillText(bd.glyph, P.x - hw - 11, P.y - hh - 5)
      }

      // labels — objects carry theirs INSIDE the chip; agents/ext below the dot
      g.textAlign = "center"
      if (P.kind === "obj") {
        g.fillStyle = C.ink
        g.globalAlpha = (objBusy ? 1 : 0.95) * dim
        g.font = `600 12px ${MONO}`
        g.textBaseline = "middle"
        g.fillText(label, P.x, P.y + 0.5)
      } else {
        g.fillStyle = C.ink
        g.globalAlpha = P.kind === "agent" ? 0.95 : 0.75 * dim
        g.font = `${P.kind === "agent" ? "600 11.5" : "500 11.5"}px ${MONO}`
        g.textBaseline = "top"
        g.fillText(label, P.x, P.y + hh + 7)
      }
      g.globalAlpha = 1

      // the session label the slot serves — a dim second line under the slot id
      if (sessLabel) {
        g.fillStyle = C.ink
        g.globalAlpha = 0.55
        g.font = `500 9.5px ${MONO}`
        g.textAlign = "center"
        g.textBaseline = "top"
        g.fillText(this.trunc(sessLabel), P.x, P.y + hh + 20)
        g.globalAlpha = 1
      }

      // status line under busy nodes
      let stxt = null
      let scol = null
      if (st === "thinking") {
        stxt = (snow - ag.since).toFixed(0) + "s"
        scol = C.ember
      } else if (st === "waiting") {
        stxt = "» " + ag.waitOn
        scol = C.warn
      } else if (st === "spawning") {
        stxt = "spawning…"
        scol = C.info
      } else if (objBusy) {
        stxt = (snow - objBusy.since).toFixed(0) + "s"
        scol = C.warn
      }
      if (stxt) {
        // agents with a session sub-line push the status line down another row
        const agentStatusY = sess ? P.y + hh + 33 : P.y + hh + 21
        g.fillStyle = scol
        g.font = `600 10.5px ${MONO}`
        g.textAlign = "center"
        g.textBaseline = "top"
        g.fillText(stxt, P.x, P.kind === "obj" ? P.y + hh + 8 : agentStatusY)
      }
    }

    this.raf = requestAnimationFrame(() => this.draw())
  },

  // ── debug rig (?debug=1 only) ────────────────────────────────────────────────
  dbg(s) {
    if (!this.debug) return
    this.DBG.push(`${new Date().toLocaleTimeString("en-GB")} ${s}`)
    if (this.DBG.length > 400) this.DBG.shift()
  },

  renderDbg() {
    const snow = this.feedNow()
    const rows = Object.values(this.AG).map((a) => {
      const el = a.since > 0 ? (snow - a.since).toFixed(0) + "s" : "–"
      return `${this.short(a.name).padEnd(9)} ${a.state.padEnd(8)} ${(a.waitOn || "").padEnd(7)} q=${a.queue} ${el}`
    })
    const cids = Object.entries(this.CID).map(([c, a]) => `${c} → ${this.short(a)}`)
    this.q("dbgstate").textContent =
      "AGENT      STATE    WAIT    Q  AGE\n" +
      rows.join("\n") +
      (cids.length ? "\n\nOPEN CID → SLOT\n" + cids.join("\n") : "")
    this.q("dbglog").textContent = this.DBG.slice(-150).reverse().join("\n")
  },

  async copyDbg() {
    const txt = this.q("dbgstate").textContent + "\n\n" + this.q("dbglog").textContent
    try {
      await navigator.clipboard.writeText(txt)
    } catch (e) {
      const t = document.createElement("textarea")
      t.value = txt
      document.body.appendChild(t)
      t.select()
      document.execCommand("copy")
      t.remove()
    }
    const b = this.q("copy")
    b.textContent = "✓ copied"
    setTimeout(() => (b.textContent = "⧉ copy"), 1200)
  },

  // ── small helpers ────────────────────────────────────────────────────────────
  feedNow() {
    return Date.now() / 1000 - this.skew
  },

  short(n) {
    return String(n).replace("wingston_agent_", "agent_").replace("conversation_sample", "convo")
  },

  // canvas labels share tight columns — long handles get an ellipsis
  trunc(s) {
    s = String(s)
    return s.length > 14 ? s.slice(0, 13) + "…" : s
  },

  // deterministic jdenticon avatar for a seed (telegram handle), rendered ONCE
  // into an offscreen canvas and cached — the draw loop just blits it. Rendered
  // oversized (48px) so the tiny bubble stays crisp; nulls on any failure so a
  // bad seed never breaks the frame.
  avatarFor(seed) {
    if (!seed) return null
    if (seed in this.AVATARS) return this.AVATARS[seed]
    // this dashboard runs 24/7; drop the cache wholesale if the churn of distinct
    // seeds grows large rather than leaking canvases forever
    if (Object.keys(this.AVATARS).length > 500) this.AVATARS = {}
    let av = null
    try {
      const S = 48
      const c = document.createElement("canvas")
      c.width = c.height = S
      jdenticon.drawIcon(c.getContext("2d"), String(seed), S)
      av = c
    } catch (e) {
      this.dbg(`avatar gen failed for ${seed}: ${e.message}`)
    }
    return (this.AVATARS[seed] = av)
  },
}
