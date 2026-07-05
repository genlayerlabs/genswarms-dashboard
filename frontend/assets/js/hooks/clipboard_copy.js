// One-click debugging handoff: the server pushes {text} on "clipboard-copy";
// we write it to the clipboard and flash the button label as feedback.
export const ClipboardCopy = {
  mounted() {
    this.handleEvent("clipboard-copy", ({ text }) => {
      navigator.clipboard
        .writeText(text)
        .then(() => this.flash("copied ✓"))
        .catch(() => this.flash("copy failed"))
    })
  },

  flash(label) {
    const orig = this.el.dataset.label || this.el.textContent
    this.el.dataset.label = orig
    this.el.textContent = label
    clearTimeout(this._t)
    this._t = setTimeout(() => (this.el.textContent = orig), 1500)
  },
}
