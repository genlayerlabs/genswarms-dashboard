// Renders the swarm topology with cytoscape (loaded from CDN as window.cytoscape).
// Objects (deterministic) and agents (LLM, per-session) get distinct shapes/colors.
// The LiveView pushes the graph via the "topology:graph" event on each snapshot.
export const Topology = {
  mounted() {
    this.cy = null;
    this.handleEvent("topology:graph", (graph) => this.render(graph));
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

    if (this.cy) {
      this.cy.json({ elements });
      this.cy.layout(this.layout()).run();
      return;
    }

    this.cy = cytoscape({
      container: this.el,
      elements,
      style: [
        {
          selector: "node[type='object']",
          style: {
            shape: "round-rectangle",
            "background-color": "#3b82f6",
            label: "data(label)",
            color: "#fff",
            "font-size": 9,
            "text-valign": "center",
            width: 70,
            height: 30,
          },
        },
        {
          selector: "node[type='agent']",
          style: {
            shape: "ellipse",
            "background-color": "#22c55e",
            label: "data(label)",
            "font-size": 8,
            "text-valign": "bottom",
            "text-margin-y": 4,
            width: 26,
            height: 26,
          },
        },
        {
          selector: "node[state='active']",
          style: { "border-width": 3, "border-color": "#16a34a" },
        },
        {
          selector: "edge",
          style: {
            width: 1.5,
            "line-color": "#94a3b8",
            "target-arrow-color": "#94a3b8",
            "target-arrow-shape": "triangle",
            "curve-style": "bezier",
            opacity: 0.6,
          },
        },
      ],
      layout: this.layout(),
    });
  },
  layout() {
    return { name: "breadthfirst", directed: true, padding: 24, spacingFactor: 1.1 };
  },
};
