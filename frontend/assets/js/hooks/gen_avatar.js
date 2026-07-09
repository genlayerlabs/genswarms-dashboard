// Draws the SAME deterministic jdenticon as the topology canvas onto a small
// avatar element, so one user wears one face on every page. Element contract:
// data-seed (already sha256-hashed server-side when privacy mode is on — this
// hook never sees a raw handle in that case) + a child <canvas> sized by CSS.
import * as jdenticon from "../../vendor/jdenticon"

export const GenAvatar = {
  mounted() {
    this.draw()
  },
  updated() {
    this.draw()
  },
  draw() {
    const canvas = this.el.querySelector("canvas")
    const seed = this.el.dataset.seed
    if (!canvas || !seed) return
    const ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    jdenticon.drawIcon(ctx, String(seed), Math.min(canvas.width, canvas.height))
  },
}
