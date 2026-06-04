// Renders the swarm topology with cytoscape (vendored locally as window.cytoscape).
// Objects (deterministic) are rectangles; agents (LLM, per-session) are dots that
// glow green when live. A force ("cose") layout keeps it legible as agents scale;
// search focuses, clicking a node isolates its neighborhood, and clicking an agent
// opens the shared inspector. The LiveView pushes the graph on each snapshot.
const COLORS = {
  object: "#3b82f6",
  agentLive: "#34d399",
  agentLiveBorder: "#10b981",
  agentIdle: "#94a3b8",
  edge: "#64748b",
};

export const Topology = {
  mounted() {
    this.cy = null;
    this.handleEvent("topology:graph", (graph) => this.render(graph));
    this.handleEvent("topology:event", (ev) => this.applyEvent(ev));
    this.handleEvent("topology:focus", ({ q }) => this.focus(q));
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
          this.cy.add({ data: { id: payload.name, label: payload.name, type: "agent", state: "active" } });
          this.cy.layout(this.layout()).run();
        }
        break;
      }
      case "message_routed":
      case "message_broadcast":
        this.flashEdge(payload.from, payload.to);
        break;
      // topology_changed: the next 3s snapshot reloads nodes/edges.
    }
  },

  flashEdge(from, to) {
    if (!from || !to) return;
    const e = this.cy.edges(`[source = "${from}"][target = "${to}"]`);
    if (e.empty()) return;
    e.animate({ style: { "line-color": COLORS.agentLive, width: 3, opacity: 1 } }, { duration: 150 })
      .animate({ style: { "line-color": COLORS.edge, width: 1.5, opacity: 0.55 } }, { duration: 500 });
  },

  destroyed() {
    if (this.cy) this.cy.destroy();
  },

  render(data) {
    const cytoscape = window.cytoscape;
    if (!cytoscape) {
      this.el.textContent = "cytoscape not loaded";
      return;
    }
    const elements = [...(data.nodes || []), ...(data.edges || [])];

    // Subsequent snapshots patch in place — only re-run the layout when nodes or
    // edges are actually added/removed, so the 3s poll doesn't reshuffle the graph
    // (or wipe the user's focus) when only an agent's state changed.
    if (this.cy) {
      this.patch(data);
      return;
    }

    this.cy = cytoscape({
      container: this.el,
      elements,
      minZoom: 0.2,
      maxZoom: 2.5,
      style: [
        {
          selector: "node[type='object']",
          style: {
            shape: "round-rectangle",
            "background-color": COLORS.object,
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
            opacity: 0.5,
          },
        },
        { selector: ".dim", style: { opacity: 0.1, "text-opacity": 0.1 } },
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
      this.isolate(n);
      if (n.data("type") === "agent" && n.data("session")) {
        this.pushEvent("inspect", { session_id: n.data("session") });
      }
    });
    // Click empty canvas → reset.
    this.cy.on("tap", (evt) => {
      if (evt.target === this.cy) this.clearFocus();
    });
  },

  // Reconcile the live graph against a new snapshot WITHOUT disturbing positions
  // unless the structure changed. Returns nothing; re-layouts only on add/remove.
  patch(data) {
    const cy = this.cy;
    const incoming = [...(data.nodes || []), ...(data.edges || [])];
    const nextIds = new Set(incoming.map((e) => e.data.id));
    let structural = false;

    cy.batch(() => {
      // drop elements that vanished
      cy.elements().forEach((el) => {
        if (!nextIds.has(el.id())) {
          el.remove();
          structural = true;
        }
      });
      // add new elements; update mutable data (state/label) on existing ones in place
      incoming.forEach(({ data: d }) => {
        const el = cy.getElementById(d.id);
        if (el.empty()) {
          cy.add({ group: d.source ? "edges" : "nodes", data: d });
          structural = true;
        } else {
          if (el.data("state") !== d.state) el.data("state", d.state);
          if (el.data("label") !== d.label) el.data("label", d.label);
        }
      });
    });

    // Only a real topology change re-seeds the layout (and clears focus).
    if (structural) {
      cy.elements().removeClass("dim hl");
      cy.layout(this.layout()).run();
    }
  },

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
      const hay = `${n.data("label") || ""} ${n.data("session") || ""} ${n.data("id") || ""}`.toLowerCase();
      return hay.includes(q);
    });
    if (match.empty()) return;

    this.cy.elements().addClass("dim");
    match.removeClass("dim").addClass("hl");
    match.neighborhood().removeClass("dim");
    this.cy.animate({ fit: { eles: match, padding: 80 } }, { duration: 250 });
  },

  layout() {
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
    };
  },
};
