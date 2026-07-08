// Local-day separators for the conversation list. Client-side on purpose: the
// server only speaks UTC (same reasoning as local_time.js) — a server-rendered
// separator would sit at the UTC boundary and misplace around midnight in the
// viewer's zone. Idempotent: every pass removes its own rows and rebuilds from
// the children's data-ts. Re-pins the inspector scroll if it was at the bottom
// (ScrollBottom runs before us and separator insertion changes list height).
export const ConversationDays = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    const el = this.el
    const scroller = el.closest(".inspector-panel") || el.parentElement
    const pinned =
      scroller && Math.abs(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop) < 8

    el.querySelectorAll("[data-day-sep]").forEach((n) => n.remove())

    let prev = null
    for (const child of Array.from(el.children)) {
      const ts = parseFloat(child.dataset.ts)
      if (!isFinite(ts)) continue
      const day = new Date(ts * 1000).toDateString()
      if (day !== prev) {
        const sep = document.createElement("div")
        sep.setAttribute("data-day-sep", "1")
        sep.className = "msg-day-sep"
        sep.textContent = new Date(ts * 1000).toLocaleDateString([], {
          month: "long",
          day: "numeric",
        })
        el.insertBefore(sep, child)
      }
      prev = day
    }

    if (pinned) scroller.scrollTop = scroller.scrollHeight
  },
}
