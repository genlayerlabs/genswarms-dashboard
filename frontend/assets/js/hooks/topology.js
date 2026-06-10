// Renders the swarm topology with cytoscape (vendored locally as window.cytoscape),
// laid out with the vendored fcose force layout (falls back to "cose" if fcose is
// absent). Objects (deterministic) are rectangles colored by subtype; agents (LLM,
// per-session) are dots that glow green when live. Edges carry *recent-traffic heat*
// tallied from live message events — they thicken/warm with volume and a small packet
// animates source→target on each message. Adding/removing nodes preserves the existing
// nodes' positions (only new nodes are placed) so a 3s poll never reshuffles the graph.
// Search focuses, clicking a node isolates its neighborhood, clicking an agent opens the
// inspector, and the legend chips toggle categories. The LiveView pushes the graph on
// each snapshot and the "re-layout" button / legend dispatch window events we listen for.

const COLORS = {
  object: "#3b82f6",
  agentLive: "#34d399",
  agentLiveBorder: "#10b981",
  agentIdle: "#94a3b8",
  edge: "#64748b",
  edgeHot: "#f97316", // hot traffic ramps the edge toward this
};

// Object subtypes → accent color. The subtype string comes from the backend
// (Aggregate.subtype/1: the handler module's last segment, underscored). Unknown
// subtypes keep the generic object blue. Add entries here as new object kinds appear.
const SUBTYPE = {
  ingress: "#6366f1",
  policy: "#a855f7",
  roster: "#0ea5e9",
  sender: "#14b8a6",
  commands: "#eab308",
  cron: "#f43f5e",
};

const TRAFFIC = {
  decayMs: 2000, // how often heat decays
  maxHeat: 8, // count that maps to a fully-hot edge
  labelMin: 3, // only label an edge at/above this count
  maxPackets: 40, // cap concurrent packet sprites
};

// ── small helpers ─────────────────────────────────────────────────────────────
const hexRgb = (h) => {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const mix = (a, b, t) => {
  const pa = hexRgb(a);
  const pb = hexRgb(b);
  const c = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
};
const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const jitter = () => Math.random() * 24 - 12;

export const Topology = {
  mounted() {
    this.cy = null;
    this.traffic = new Map(); // edge id ("from__to") → heat (float)
    this.packets = 0;
    this.pktSeq = 0;
    this.hidden = new Set(); // legend categories toggled off
    this.decayTimer = null;
    this.tooltip = document.createElement("div");
    this.tooltip.className = "topo-tip";
    this.tooltip.style.display = "none";
    this.el.appendChild(this.tooltip);

    this.handleEvent("topology:graph", (graph) => this.render(graph));
    this.handleEvent("topology:event", (ev) => this.applyEvent(ev));
    this.handleEvent("topology:focus", ({ q }) => this.focus(q));

    this.onRelayout = () => this.relayout();
    this.onToggle = (e) => this.toggleCategory(e.detail && e.detail.cat);
    window.addEventListener("topology:relayout", this.onRelayout);
    window.addEventListener("topology:toggle", this.onToggle);
  },

  destroyed() {
    window.removeEventListener("topology:relayout", this.onRelayout);
    window.removeEventListener("topology:toggle", this.onToggle);
    if (this.decayTimer) clearInterval(this.decayTimer);
    if (this.tooltip) this.tooltip.remove();
    if (this.cy) this.cy.destroy();
  },

  // Incremental live update from a swarm WS event.
  applyEvent({ type, payload }) {
    if (!this.cy) return;
    switch (type) {
      case "agent_status": {
        const n = this.cy.getElementById(payload.agent);
        if (n.nonempty()) n.data("state", payload.state);
        break;
      }
      case "agent_removed": {
        const n = this.cy.getElementById(payload.name);
        if (n.nonempty()) n.remove();
        break;
      }
      case "agent_added": {
        if (payload.name && this.cy.getElementById(payload.name).empty()) {
          const ele = this.cy.add({ data: { id: payload.name, label: payload.name, type: "agent", state: "active" } });
          this.placeNew([ele]); // place just the new node; keep everyone else put
        }
        break;
      }
      case "message_routed":
      case "message_broadcast":
        this.bumpTraffic(payload.from, payload.to);
        this.sendPacket(payload.from, payload.to);
        break;
      // topology_changed: the next 3s snapshot reloads nodes/edges.
    }
  },

  // ── traffic heat ──────────────────────────────────────────────────────────────
  // Per-edge "heat" accumulated from live message events and decayed on a timer, so
  // the graph reflects RECENT traffic rather than all-time totals.
  bumpTraffic(from, to) {
    if (!from || !to) return;
    const k = `${from}__${to}`;
    this.traffic.set(k, (this.traffic.get(k) || 0) + 1);
    this.restyleEdges();
    if (!this.decayTimer) this.decayTimer = setInterval(() => this.decayTraffic(), TRAFFIC.decayMs);
  },

  // DECISION POINT — this defines what the edge heat MEANS to an operator.
  // TODO(you): pick the decay policy (~8 lines). Options & trade-offs:
  //   • exponential decay (scaffolded below): heat *= DECAY each tick — smooth, cheap,
  //     reads as "warmth fades"; DECAY closer to 1 = slower cooldown.
  //   • sliding window: store per-edge event timestamps, count only the last N seconds —
  //     gives an exact msgs/sec, but more bookkeeping and memory.
  //   • all-time totals: delete this method and never decay — simplest, but a long-lived
  //     swarm saturates every edge and the heat stops being informative.
  decayTraffic() {
    const DECAY = 0.7;
    let any = false;
    for (const [k, v] of this.traffic) {
      const n = v * DECAY;
      if (n < 0.05) this.traffic.delete(k);
      else this.traffic.set(k, n);
      any = true;
    }
    if (any) this.restyleEdges();
    if (this.traffic.size === 0 && this.decayTimer) {
      clearInterval(this.decayTimer);
      this.decayTimer = null;
    }
  },

  // Imperatively restyle every edge from its current heat (width/color/opacity) and
  // label the busy ones. Imperative (not mapData) so it never trips on a missing attr.
  restyleEdges() {
    if (!this.cy) return;
    this.cy.batch(() => {
      this.cy.edges().forEach((e) => {
        const c = this.traffic.get(e.id()) || 0;
        const h = Math.min(c / TRAFFIC.maxHeat, 1);
        e.style({
          width: 1.5 + h * 4.5,
          "line-color": h > 0 ? mix(COLORS.edge, COLORS.edgeHot, h) : COLORS.edge,
          "target-arrow-color": h > 0 ? mix(COLORS.edge, COLORS.edgeHot, h) : COLORS.edge,
          opacity: 0.4 + h * 0.55,
        });
        e.data("tlabel", c >= TRAFFIC.labelMin ? String(Math.round(c)) : "");
      });
    });
  },

  // Animate a small packet sprite from source → target along the edge — shows both
  // that a message flowed AND its direction, where the old flash only blinked.
  sendPacket(from, to) {
    if (!this.cy || this.packets >= TRAFFIC.maxPackets) return;
    const src = this.cy.getElementById(from);
    const tgt = this.cy.getElementById(to);
    if (src.empty() || tgt.empty()) return;
    const p0 = src.position();
    const p1 = tgt.position();
    this.packets++;
    this.pktSeq++;
    const pkt = this.cy.add({
      group: "nodes",
      data: { id: `pkt_${this.pktSeq}`, packet: true },
      position: { x: p0.x, y: p0.y },
      selectable: false,
      grabbable: false,
    });
    pkt.style({
      "background-color": COLORS.edgeHot,
      width: 7,
      height: 7,
      "border-width": 0,
      label: "",
      events: "no",
      "z-index": 9999,
    });
    pkt.animate(
      { position: { x: p1.x, y: p1.y } },
      {
        duration: 450,
        complete: () => {
          pkt.remove();
          this.packets--;
        },
      },
    );
  },

  render(data) {
    const cytoscape = window.cytoscape;
    if (!cytoscape) {
      this.el.textContent = "cytoscape not loaded";
      return;
    }

    // Subsequent snapshots patch in place — see patch() — so the 3s poll never
    // reshuffles the graph or wipes the user's focus.
    if (this.cy) {
      this.patch(data);
      return;
    }

    const nodes = (data.nodes || []).map((n) => ({ data: this.normNode(n.data) }));
    const edges = (data.edges || []).map((e) => ({ data: { ...e.data, heat: 0, tlabel: "" } }));

    this.cy = cytoscape({
      container: this.el,
      elements: [...nodes, ...edges],
      minZoom: 0.2,
      maxZoom: 2.5,
      style: [
        {
          selector: "node[type='object']",
          style: {
            shape: "round-rectangle",
            "background-color": "data(ocolor)", // subtype accent (Aggregate.subtype/1)
            label: "data(label)",
            color: "#fff",
            "font-size": 9,
            "font-weight": 600,
            "text-valign": "center",
            "text-max-width": 64,
            "text-wrap": "ellipsis",
            width: 74,
            height: 30,
          },
        },
        {
          selector: "node[type='agent']",
          style: {
            shape: "ellipse",
            "background-color": COLORS.agentIdle,
            "border-width": 2,
            "border-color": "rgba(148,163,184,0.4)",
            label: "data(label)",
            color: "currentColor",
            "font-size": 8,
            "font-family": "JetBrains Mono, monospace",
            "text-valign": "bottom",
            "text-margin-y": 4,
            width: 22,
            height: 22,
          },
        },
        {
          selector: "node[type='agent'][state='active']",
          style: {
            "background-color": COLORS.agentLive,
            "border-width": 4,
            "border-color": COLORS.agentLiveBorder,
            "border-opacity": 0.5,
            width: 26,
            height: 26,
          },
        },
        {
          selector: "edge",
          style: {
            width: 1.5,
            "line-color": COLORS.edge,
            "target-arrow-color": COLORS.edge,
            "target-arrow-shape": "triangle",
            "arrow-scale": 0.8,
            "curve-style": "bezier",
            opacity: 0.4,
            label: "data(tlabel)",
            "font-size": 7,
            color: COLORS.edgeHot,
            "text-background-color": "#ffffff",
            "text-background-opacity": 0.7,
            "text-background-padding": 1,
          },
        },
        { selector: ".dim", style: { opacity: 0.1, "text-opacity": 0.1 } },
        { selector: ".cat-hidden", style: { display: "none" } },
        {
          selector: "node.hl",
          style: { "border-width": 4, "border-color": "#f59e0b", "border-opacity": 1 },
        },
      ],
      layout: this.layout(),
    });

    // Click a node → isolate its neighborhood; agents also open the inspector.
    this.cy.on("tap", "node", (evt) => {
      const n = evt.target;
      if (n.data("packet")) return;
      this.isolate(n);
      if (n.data("type") === "agent" && n.data("session")) {
        this.pushEvent("inspect", { session_id: n.data("session") });
      }
    });
    // Click empty canvas → reset.
    this.cy.on("tap", (evt) => {
      if (evt.target === this.cy) this.clearFocus();
    });
    // Hover → tooltip; any pan/zoom/drag dismisses it.
    this.cy.on("mouseover", "node", (evt) => this.showTip(evt.target));
    this.cy.on("mouseout", "node", () => this.hideTip());
    this.cy.on("pan zoom drag", () => this.hideTip());

    this.restyleEdges();
  },

  // Reconcile the live graph against a new snapshot WITHOUT disturbing positions:
  // existing nodes stay put, only genuinely-new nodes get placed. Transient packet
  // sprites are ignored so an in-flight packet can't be mistaken for a removed node.
  patch(data) {
    const cy = this.cy;
    const incoming = [...(data.nodes || []), ...(data.edges || [])];
    const nextIds = new Set(incoming.map((e) => e.data.id));
    const added = [];

    cy.batch(() => {
      // drop elements that vanished (never touch packet sprites)
      cy.elements().forEach((el) => {
        if (el.data("packet")) return;
        if (!nextIds.has(el.id())) el.remove();
      });
      // add new elements; update mutable data (state/label) on existing ones in place
      incoming.forEach(({ data: d }) => {
        const el = cy.getElementById(d.id);
        if (el.empty()) {
          const isEdge = !!d.source;
          const ele = cy.add({
            group: isEdge ? "edges" : "nodes",
            data: isEdge ? { ...d, heat: 0, tlabel: "" } : this.normNode(d),
          });
          if (!isEdge) added.push(ele);
        } else {
          if (el.data("state") !== d.state) el.data("state", d.state);
          if (el.data("label") !== d.label) el.data("label", d.label);
          if (d.type === "object") el.data("ocolor", this.normNode(d).ocolor);
        }
      });
    });

    if (added.length) this.placeNew(added); // place only the newcomers
    this.applyHidden();
    this.restyleEdges();
  },

  // Give object nodes a subtype-derived accent color (agents are left untouched).
  normNode(d) {
    if (d.type === "object") return { ...d, ocolor: SUBTYPE[d.subtype] || COLORS.object };
    return d;
  },

  // ── layout ──────────────────────────────────────────────────────────────────
  // fcose if the vendored extension registered itself (window.cytoscapeFcose), else
  // cose. `extra` overrides per call (e.g. fixedNodeConstraint for incremental adds).
  layout(extra = {}) {
    if (typeof window.cytoscapeFcose !== "undefined") {
      return {
        name: "fcose",
        animate: false,
        quality: "default",
        randomize: false,
        fit: true,
        padding: 30,
        nodeRepulsion: 9000,
        idealEdgeLength: 90,
        nodeSeparation: 75,
        ...extra,
      };
    }
    return {
      name: "cose",
      animate: false,
      padding: 30,
      nodeRepulsion: 9000,
      idealEdgeLength: 90,
      nodeOverlap: 14,
      gravity: 0.45,
      componentSpacing: 90,
      randomize: false,
      fit: true,
      ...extra,
    };
  },

  // Place only the new nodes: seed each near its already-placed neighbors (or the
  // graph centroid), pin every existing node, and let fcose settle the newcomers.
  // (Under the cose fallback fixedNodeConstraint is ignored, so this degrades to a
  // full reflow — acceptable; fcose is the intended path.)
  placeNew(newNodes) {
    const cy = this.cy;
    const isNew = new Set(newNodes.map((n) => n.id()));
    const centroid = this.centroid();
    newNodes.forEach((n) => {
      const placed = n.neighborhood("node").filter((m) => !isNew.has(m.id()) && !m.data("packet"));
      const seed = placed.nonempty() ? this.avgPos(placed) : centroid;
      n.position({ x: seed.x + jitter(), y: seed.y + jitter() });
    });
    const fixed = cy
      .nodes()
      .filter((n) => !isNew.has(n.id()) && !n.data("packet"))
      .map((n) => ({ nodeId: n.id(), position: { x: n.position("x"), y: n.position("y") } }));
    cy.layout(this.layout({ fit: false, fixedNodeConstraint: fixed })).run();
  },

  centroid() {
    const ns = this.cy.nodes().filter((n) => !n.data("packet"));
    if (ns.empty()) return { x: 0, y: 0 };
    return this.avgPos(ns);
  },

  avgPos(nodes) {
    let x = 0;
    let y = 0;
    nodes.forEach((n) => {
      x += n.position("x");
      y += n.position("y");
    });
    return { x: x / nodes.length, y: y / nodes.length };
  },

  // Manual full reflow (the "re-layout" button) — randomized so it untangles cleanly.
  relayout() {
    if (!this.cy) return;
    this.cy.layout(this.layout({ randomize: true, fit: true })).run();
  },

  // ── focus / isolation ─────────────────────────────────────────────────────────
  isolate(node) {
    const hood = node.closedNeighborhood();
    this.cy.elements().addClass("dim");
    hood.removeClass("dim");
    node.addClass("hl");
  },

  clearFocus() {
    if (this.cy) this.cy.elements().removeClass("dim hl");
  },

  focus(q) {
    if (!this.cy) return;
    q = (q || "").trim().toLowerCase();
    this.cy.elements().removeClass("dim hl");
    if (!q) return;

    const match = this.cy.nodes().filter((n) => {
      if (n.data("packet")) return false;
      const hay = `${n.data("label") || ""} ${n.data("session") || ""} ${n.data("id") || ""}`.toLowerCase();
      return hay.includes(q);
    });
    if (match.empty()) return;

    this.cy.elements().addClass("dim");
    match.removeClass("dim").addClass("hl");
    match.neighborhood().removeClass("dim");
    this.cy.animate({ fit: { eles: match, padding: 80 } }, { duration: 250 });
  },

  // ── legend category toggles ─────────────────────────────────────────────────
  toggleCategory(cat) {
    if (!cat) return;
    if (this.hidden.has(cat)) this.hidden.delete(cat);
    else this.hidden.add(cat);
    this.applyHidden();
  },

  applyHidden() {
    if (!this.cy) return;
    const sel = {
      object: "node[type='object']",
      "agent-live": "node[type='agent'][state='active']",
      "agent-idle": "node[type='agent'][state!='active']",
    };
    this.cy.batch(() => {
      this.cy.elements().removeClass("cat-hidden");
      this.hidden.forEach((c) => {
        if (sel[c]) this.cy.$(sel[c]).addClass("cat-hidden");
      });
    });
  },

  // ── hover tooltip ─────────────────────────────────────────────────────────────
  showTip(n) {
    if (n.data("packet")) return;
    const d = n.data();
    const rows = [
      `<b>${esc(d.label || d.id)}</b>`,
      d.type === "object" ? `object · ${esc(d.subtype || "—")}` : `agent · ${esc(d.state || "idle")}`,
      d.session ? `session ${esc(d.session)}` : "",
    ].filter(Boolean);
    this.tooltip.innerHTML = rows.join("<br>");
    const rp = n.renderedPosition();
    this.tooltip.style.left = `${rp.x + 12}px`;
    this.tooltip.style.top = `${rp.y + 12}px`;
    this.tooltip.style.display = "block";
  },

  hideTip() {
    if (this.tooltip) this.tooltip.style.display = "none";
  },
};
