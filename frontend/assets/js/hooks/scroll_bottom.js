// Keeps a scroll container pinned to its newest content (chat-style): jump to
// the bottom when it first renders, follow new content only while the reader
// is already near the bottom — never yank someone who scrolled up to read.
export const ScrollBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
  },
  updated() {
    const nearBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 120
    if (nearBottom) this.el.scrollTop = this.el.scrollHeight
  },
}
