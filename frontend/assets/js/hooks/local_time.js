// Renders an absolute timestamp in the BROWSER's time zone. The server can only
// speak UTC (no tz database in the release); the viewer's clock is the honest
// reference for an ops dashboard, so the conversion happens client-side.
// Element contract: data-ts (unix seconds, float ok) + data-fmt ("hm" | "hms").
// The server-rendered text is the UTC fallback (shown until the hook runs / no JS).
export const LocalTime = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    const ts = parseFloat(this.el.dataset.ts)
    if (!isFinite(ts)) return
    const opts =
      this.el.dataset.fmt === "hms"
        ? {hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false}
        : {hour: "2-digit", minute: "2-digit", hour12: false}
    this.el.textContent = new Date(ts * 1000).toLocaleTimeString([], opts)
  },
}
