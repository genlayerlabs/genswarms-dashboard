// Remembers the sensitive-content reveal per browser and replays it on every
// LiveView mount, so "Reveal conversations" is one click ever — not one per
// navigation. The server owns the gate (content isn't fetched until revealed);
// localStorage only stores the boolean preference, never any content.
const KEY = "dash-reveal-transcripts"

export const TranscriptGate = {
  mounted() {
    if (localStorage.getItem(KEY) === "1") this.pushEvent("transcripts_reveal", {})
    this.handleEvent("transcripts:store", ({show}) => {
      localStorage.setItem(KEY, show ? "1" : "0")
    })
  },
}
