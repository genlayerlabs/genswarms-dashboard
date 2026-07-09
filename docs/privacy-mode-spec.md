# Privacy mode — spec (2026-07-08, approved by Albert)

Frontend-only demo/screen-share privacy toggle. When ON, the dashboard shows the
swarm working — slots, states, edges, timings, counts — but **no user data**:
no handles, no names, no conversation text, no session/chat ids. Users are
identifiable ONLY by their generated (jdenticon) avatar. Threat model is
screen-sharing, not deployment lockdown: redaction happens **server-side at
render time** in the frontend LiveViews, so the DOM never contains the data
while privacy is on (devtools-clean). The backend and its API are untouched.

## Decisions (locked)

- **Toggle = eye icon in the top nav only.** No settings/config page entry.
  While ON, a visible "privacy" badge sits in the header (you must be able to
  see at a glance that you're safe). Toggle available on every page.
- **State lives in the Plug session cookie**, set by a controller action
  (`POST /privacy/toggle` + redirect back). `DashHooks.on_mount` (the shared
  `live_session :dashboard` hook) reads it into a `@privacy` assign for every
  LiveView. Server-side state means a reload in privacy mode never flashes
  user data — a localStorage/JS-hook design would, and is therefore rejected.
- **Avatars stay seeded by handle** (topology #23 mechanism); the seed itself
  never renders. Avatar = the only stable identity anchor in privacy mode.
- **Redact, keep structure** (not hide pages) — except Logs, which is raw
  transcript and renders a "hidden in privacy mode" notice instead.
- **No redaction in SwarmClient/EngineClient**: their caches are shared across
  viewers; per-viewer privacy would bleed between sessions. Render-time only.

## One shared module owns all masking: `PrivacyRedactor`

`frontend/lib/subzero_swarm_dashboard/privacy_redactor.ex` — pure functions,
unit-tested:

- `mask_cid(text)` — replaces cid-shaped substrings in free text:
  `tg:-?<digits>:<digits>` and legacy `tg_<digits>_<digits>` → `tg:•••`.
  Also masks bare telegram-id-shaped tokens when they appear in id-labeled
  contexts (see mask_identity), NOT blanket digit-scrubbing of free text.
- `mask_identity(term)` — deep-walks maps/lists (string AND atom keys). Values
  under identity keys are replaced with `"•••"`:
  `handle, username, name, first_name, last_name, label, user, session_id,
  cid, conversation_id, chat_id, from` (a map under `user`/`identity` is
  recursed; scalars under those keys masked). Numbers, states, timestamps,
  counts, modes and every other key pass through untouched.
- `mask_text(_)` — free text (message bodies, log lines) → `"▪▪▪▪▪"` (fixed,
  length-independent — length itself can leak).

Every LiveView pipes its identity-bearing assigns through these AT RENDER
PREP (mount/handle_info), gated on `@privacy`.

## Per-page behavior when ON

| Page | Keeps | Masks |
|---|---|---|
| Topology | slots, edges, avatars, node states | session-id text labels (slot name only) |
| Sessions list | avatar, slot, state, timestamps, counts | `label`/handle/name, session ids |
| Session detail (conversation panel) | bubble sides/kinds/timestamps, thread shape | every message body → `mask_text`; header shows avatar only |
| Events | kind, level, category, timestamp | `message` text → `mask_text`; metadata through `mask_identity` + `mask_cid` |
| Logs | notice "hidden in privacy mode" + line count | everything else |
| Overview / Usage / Config | aggregates unchanged | `mask_cid` sweep over warnings/labels/strings |
| Extension pages (Growth, consumers, …) | counts, numeric series, page chrome | whole extension payload through `mask_identity` (arbitrary shapes stay safe) |

## Tests (canary pattern)

- `PrivacyRedactor` unit suite: cid shapes (incl. negative group ids), nested
  string/atom-keyed payloads, non-identity keys untouched.
- Per-page LiveView tests with a canary fixture (handle `canary_h4ndle`, name
  `Canary Q. Name`, cid `tg:987654321:0`, message text `CANARY-TEXT`): with
  privacy ON, `render(view)` contains NONE of the canary strings; with OFF,
  behavior unchanged (existing tests keep passing).
- Toggle test: POST toggles session, redirect returns, badge renders, state
  survives a fresh mount.

## Ship shape

genswarms-dashboard frontend `0.2.0 → 0.3.0` (feature; backend untouched at
0.3.4). Then the standard wingston vendor-pin bump (`chore(vendor): bump
genswarms-dashboard pin`) → auto-deploy. Implementation runs as Codex
subagent chunks (C1 redactor, C2 toggle plumbing, C3 topology/sessions/panel,
C4 events/logs/sweeps/extensions, C5 canary suite + version bump), each diff
reviewed before the next starts.
