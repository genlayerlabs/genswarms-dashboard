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

const FLIGHT = 1100 // packet flight time (ms)
const STAGGER = 200 // launch stagger when flushing a backlog (ms)
const TAU = Math.PI * 2

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
    this.q("copy").addEventListener("click", () => this.copyDbg())

    this.handleEvent("pipeline:init", (layout) => {
      this.LAYOUT = layout
      this.FIXED = new Set((layout.nodes || []).map((n) => n.name))
      this.BG = new Set(layout.chatter || [])
      this.refreshTheme()
      this.layout()
    })
    // snapshot wins existence: slots appear before their first event (additive —
    // a torn-down slot stays drawn idle rather than flickering between snapshots)
    this.handleEvent("pipeline:agents", ({agents}) => {
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
      this.refreshTheme() // tracks live theme switches; cheap at 1Hz
    }, 1000)
    if (this.debug) {
      const panel = this.q("dbg")
      panel.classList.remove("hidden")
      panel.classList.add("flex")
      this.dbgTimer = setInterval(() => this.renderDbg(), 500)
    }
    this.raf = requestAnimationFrame(() => this.draw())
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
      case "browse_dispatch":
        return ev.agent || null
      case "browse_done":
        return (this.AG[ev.agent] || {}).waitOn === "browse" ? "web" : "browse"
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
              if (ag) this.setState(agent, "thinking", ag.state === "thinking" ? ag.since : ts)
            },
          },
        ]
      }

      case "browse_dispatch": {
        if (!agent) return []
        this.ensureNode(agent)
        return [
          {a: agent, b: "browse", kind: "msg", st: () => this.setWaiting(agent, "browse", ts)},
          {a: "browse", b: "web", kind: "browse", v: "dispatched"},
        ]
      }

      case "browse_done": {
        if (!agent) return []
        this.ensureNode(agent)
        const v = ev.verdict || ""
        const resume = () => {
          const ag = this.AG[agent]
          if (ag && ag.state === "waiting" && ag.waitOn === "browse") this.setState(agent, "thinking", ts)
        }
        const ag = this.AG[agent]
        if (ag && ag.state === "waiting" && ag.waitOn === "browse") {
          // the reply travels web → browse → agent; the resume applies on arrival
          return [
            {a: "web", b: "browse", kind: "reply", v},
            {a: "browse", b: agent, kind: "reply", v, st: resume},
          ]
        }
        return [{a: "browse", b: agent, kind: "reply", v, st: resume}]
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
    const bg = this.isBg(op.a, op.b)
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
    return this.AG[name] || (this.AG[name] = {name, state: "idle", waitOn: null, since: 0, queue: 0})
  },

  setState(name, state, ts) {
    const ag = this.ag(name)
    this.dbg(`STATE ${this.short(name)}: ${ag.state}${ag.waitOn ? "(" + ag.waitOn + ")" : ""} → ${state}`)
    ag.state = state
    ag.waitOn = null
    ag.since = ts
  },

  setWaiting(name, on, ts) {
    const ag = this.ag(name)
    this.dbg(`STATE ${this.short(name)}: ${ag.state} → waiting(${on})`)
    ag.state = "waiting"
    ag.waitOn = on
    ag.since = ts
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
  layout() {
    if (!this.LAYOUT) return
    const W = (this.cv.width = this.cv.clientWidth || this.el.clientWidth)
    const H = (this.cv.height = this.cv.clientHeight || this.el.clientHeight)
    this.POS = {}
    for (const n of this.LAYOUT.nodes || [])
      this.POS[n.name] = {x: n.x * W, y: n.y * H, r: n.r || 18, kind: n.kind || "obj"}
    let extra = 0
    for (const n of this.EXTRAS) this.POS[n] = {x: 0.9 * W, y: (0.74 - extra++ * 0.14) * H, r: 18, kind: "obj"}
    const ags = [...this.AGENTS].sort()
    const colX = this.LAYOUT.agent_column_x || 0.47
    const gap = Math.min(0.1, 0.66 / Math.max(ags.length - 1, 1))
    ags.forEach((n, i) => {
      const y = 0.5 + (i - (ags.length - 1) / 2) * gap
      this.POS[n] = {x: colX * W, y: y * H, r: 8, kind: "agent"}
    })
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
  refreshTheme() {
    const cs = getComputedStyle(this.el)
    const v = (name, fb) => cs.getPropertyValue(name).trim() || fb
    this.C = {
      ok: v("--color-success", "#22c55e"),
      warn: v("--color-warning", "#f59e0b"),
      err: v("--color-error", "#f43f5e"),
      info: v("--color-info", "#3b82f6"),
      traffic: v("--color-primary", "#6366f1"),
      ink: v("--color-base-content", "#64748b"),
      bg: v("--color-base-100", "#ffffff"),
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
      g.globalAlpha = bg ? 0.07 + 0.1 * t : 0.18 + 0.32 * t
      g.lineWidth = bg ? 1 : 1 + t * 4
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
      g.lineWidth = 2
      g.setLineDash([7, 5])
      g.lineDashOffset = -(pnow / 40) % 12
      g.beginPath()
      g.moveTo(A.x, A.y)
      g.lineTo(B.x, B.y)
      g.stroke()
      g.restore()
      const mx = (A.x + B.x) / 2
      const my = (A.y + B.y) / 2
      const lbl = (snow - ag.since).toFixed(1) + "s"
      g.font = "10px ui-monospace"
      g.textAlign = "center"
      g.textBaseline = "middle"
      const w = g.measureText(lbl).width + 10
      g.fillStyle = C.bg
      g.globalAlpha = 0.85
      g.beginPath()
      g.roundRect(mx - w / 2, my - 9, w, 18, 5)
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
      for (let j = 0; j < 3; j++) {
        const ut = u - j * 0.055
        if (ut < 0) continue
        const pt = this.pAt(A, B, gm, ut)
        g.globalAlpha = [1, 0.45, 0.2][j]
        g.fillStyle = col
        g.beginPath()
        g.arc(pt.x, pt.y, [4, 3, 2.2][j], 0, TAU)
        g.fill()
      }
      g.globalAlpha = 1
    }

    // objects an agent is currently waiting on get a working ring too
    const busyObjs = {}
    for (const ag of Object.values(this.AG)) if (ag.state === "waiting" && ag.waitOn) busyObjs[ag.waitOn] = ag

    for (const [n, P] of Object.entries(this.POS)) {
      const ag = P.kind === "agent" ? this.AG[n] : null
      const st = ag ? ag.state : null
      const objBusy = P.kind !== "agent" && busyObjs[n]

      // body
      if (P.kind === "agent") {
        g.fillStyle = st === "thinking" ? C.ok : st === "waiting" ? C.warn : C.ink
        g.globalAlpha = st === "thinking" || st === "waiting" ? 0.9 : 0.3
      } else if (P.kind === "ext") {
        g.fillStyle = C.ink
        g.globalAlpha = 0.14
      } else {
        g.fillStyle = C.info
        g.globalAlpha = 0.16
      }
      g.beginPath()
      P.kind === "agent"
        ? g.arc(P.x, P.y, P.r, 0, TAU)
        : g.roundRect(P.x - P.r, P.y - P.r * 0.7, P.r * 2, P.r * 1.4, 5)
      g.fill()
      g.globalAlpha = P.kind === "obj" ? 0.5 : 0.3
      g.strokeStyle = P.kind === "obj" ? C.info : C.ink
      g.lineWidth = 1.5
      g.stroke()
      g.globalAlpha = 1

      // activity rings: ● pulsing thinking, ◐ steady waiting, ◌ spawning sweep
      if (st === "thinking" || objBusy) {
        g.strokeStyle = objBusy ? C.warn : C.ok
        g.lineWidth = 2
        g.beginPath()
        if (P.kind === "agent") g.arc(P.x, P.y, P.r + 3 + Math.sin(pnow / 170) * 1.6, 0, TAU)
        else g.roundRect(P.x - P.r - 5, P.y - P.r * 0.7 - 5, P.r * 2 + 10, P.r * 1.4 + 10, 7)
        g.stroke()
      } else if (st === "waiting") {
        g.strokeStyle = C.warn
        g.lineWidth = 2.5
        g.beginPath()
        g.arc(P.x, P.y, P.r + 3, 0, TAU)
        g.stroke()
      } else if (st === "spawning") {
        const a0 = (pnow / 260) % TAU
        g.strokeStyle = C.info
        g.lineWidth = 2.5
        g.lineCap = "round"
        g.beginPath()
        g.arc(P.x, P.y, P.r + 4, a0, a0 + 3.4)
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
        if (P.kind === "agent") g.arc(P.x, P.y, P.r + 6, 0, TAU)
        else g.roundRect(P.x - P.r - 6, P.y - P.r * 0.7 - 6, P.r * 2 + 12, P.r * 1.4 + 12, 8)
        g.stroke()
        g.globalAlpha = 1
      }

      // queue badge (⁺¹)
      if (ag && ag.queue > 0) {
        g.fillStyle = C.warn
        g.beginPath()
        g.arc(P.x + P.r + 4, P.y - P.r - 2, 7, 0, TAU)
        g.fill()
        g.fillStyle = C.bg
        g.font = "bold 9px ui-monospace"
        g.textAlign = "center"
        g.textBaseline = "middle"
        g.fillText(String(ag.queue), P.x + P.r + 4, P.y - P.r - 2)
      }

      // ☕ on compaction
      const bd = this.BADGE[n]
      if (bd && bd.until > pnow) {
        g.font = "12px ui-monospace"
        g.textAlign = "center"
        g.textBaseline = "middle"
        g.fillText(bd.glyph, P.x - P.r - 8, P.y - P.r - 4)
      }

      // labels
      g.fillStyle = C.ink
      g.globalAlpha = 0.85
      g.font = (P.kind === "agent" ? "9px" : "11px") + " ui-monospace"
      g.textAlign = "center"
      g.textBaseline = P.kind === "agent" ? "top" : "middle"
      g.fillText(this.short(n), P.x, P.kind === "agent" ? P.y + P.r + 5 : P.y)
      g.globalAlpha = 1

      // status line under busy nodes
      let stxt = null
      let scol = null
      if (st === "thinking") {
        stxt = (snow - ag.since).toFixed(0) + "s"
        scol = C.ok
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
        g.fillStyle = scol
        g.font = "9px ui-monospace"
        g.textAlign = "center"
        g.textBaseline = "top"
        g.fillText(stxt, P.x, P.kind === "agent" ? P.y + P.r + 15 : P.y + P.r * 0.7 + 12)
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
}
