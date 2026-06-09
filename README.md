# genswarms-dashboard

Read-only observability dashboard for a [genswarms](https://github.com/genlayerlabs/genswarms)
swarm, in two halves:

| Dir | What | Runs where |
|---|---|---|
| [`backend/`](backend/) | Generic read-API + WS live-feed relay (`GenswarmsDashboard.*`, a mix library) | **Inside the orchestrator BEAM** — vendored by the host app and loaded via `Code.require_file` (the live pool/PubSub/logs it serves are node-local) |
| [`frontend/`](frontend/) | The 7-page Phoenix LiveView UI (overview, sessions, session detail, topology, events, logs, usage) | A **separate process/machine** — talks to the backend over HTTP/WS with a token |

The two halves meet at a pinned wire contract (HTTP routes + JSON envelope + WS event
names) — documented in [`backend/README.md`](backend/README.md) and enforced by the
backend's golden contract test. The backend knows zero app/transport specifics: host apps
implement `GenswarmsDashboard.DataSource` to feed it (see wingston's
`objects/dashboard_source.ex` for the reference Telegram adapter).

## Quick start

**Frontend** (against a running orchestrator):

```sh
cd frontend
SWARM_API_URL=http://127.0.0.1:4001 SWARM_WS_URL=http://127.0.0.1:4001 \
SWARM_NAME=wingston PORT=4200 mix phx.server
```

**Backend** — not started from this repo; the host app vendors it (e.g. as a git
submodule at `vendor/genswarms-dashboard`) and calls `GenswarmsDashboard.start/1` at
boot. Vendoring instructions, the pinned require order, and the `DataSource` contract:
[`backend/README.md`](backend/README.md).

```sh
cd backend && mix test   # standalone suite; engine calls are stubbed
```
