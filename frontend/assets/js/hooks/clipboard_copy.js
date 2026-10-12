// Identity buttons copy locally; log exports receive their text from the server.
export const ClipboardCopy = {
  mounted() {
    if (this.el.dataset.copyText !== undefined) {
      this._click = event => {
        event.stopPropagation()
        this.copy(this.el.dataset.copyText)
      }
      this._keydown = event => {
        if (event.key === "Enter" || event.key === " ") event.stopPropagation()
      }
      this.el.addEventListener("click", this._click)
      this.el.addEventListener("keydown", this._keydown)
    } else {
      this.handleEvent("clipboard-copy", ({text}) => this.copy(text))
    }
  },

  async copy(text) {
    try {
      await navigator.clipboard.writeText(text)
      this.flash("copied ✓")
    } catch {
      this.flash("copy failed")
    }
  },

  flash(label) {
    this._originalHTML ??= this.el.innerHTML
    this._originalLabel ??= this.el.getAttribute("aria-label")
    this.el.textContent = label
    if (this._originalLabel) this.el.setAttribute("aria-label", label)
    clearTimeout(this._t)
    this._t = setTimeout(() => {
      this.el.innerHTML = this._originalHTML
      if (this._originalLabel) this.el.setAttribute("aria-label", this._originalLabel)
    }, 1500)
  },

  destroyed() {
    clearTimeout(this._t)
    this.el.removeEventListener("click", this._click)
    this.el.removeEventListener("keydown", this._keydown)
  },
}
