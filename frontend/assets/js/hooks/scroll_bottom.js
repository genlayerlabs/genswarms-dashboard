// Keeps a scroll container pinned to its newest content (chat-style): jump to
// the bottom when it first renders, follow new content only while the reader
// is already near the bottom — never yank someone who scrolled up to read.
export const ScrollBottom = {
  mounted() {
    this.follow = true
    this.el.scrollTop = this.el.scrollHeight
  },
  // the near-bottom decision must use PRE-patch measurements: right after content
  // loads, scrollHeight has already grown and the reader would never count as
  // "near bottom" — the first load would never follow
  beforeUpdate() {
    this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 120
  },
  updated() {
    if (this.follow) this.el.scrollTop = this.el.scrollHeight
  },
}
