// Collapsible sidebar groups. The open/closed choice is a per-browser
// preference (like TranscriptGate's reveal): stored in localStorage as the
// set of CLOSED group names — absent means open, so new groups start open.
//
// The snapshot feed re-renders the sidebar every second, and the template
// always renders `open` — so this hook is the owner of the real state and
// reapplies it on every `updated()`. The `applying` flag keeps that
// programmatic flip from echoing back into storage via the toggle event.
const KEY = "dash-nav-groups-closed"

function closedSet() {
  try {
    return new Set(JSON.parse(localStorage.getItem(KEY) || "[]"))
  } catch {
    return new Set()
  }
}

function store(set) {
  localStorage.setItem(KEY, JSON.stringify([...set]))
}

export const NavGroups = {
  mounted() {
    this.el.addEventListener("toggle", () => {
      if (this.applying) return
      const closed = closedSet()
      const group = this.el.dataset.group
      this.el.open ? closed.delete(group) : closed.add(group)
      store(closed)
    })
    this.apply()
  },

  updated() {
    this.apply()
  },

  apply() {
    this.applying = true
    this.el.open = !closedSet().has(this.el.dataset.group)
    this.applying = false
  },
}
