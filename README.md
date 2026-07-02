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

**Backend** — not started from this repo; two ways to run it inside the host BEAM:

1. **As a genswarms object** (preferred, the swarmidx-packaged form): declare
   `GenswarmsDashboard.Objects.Dashboard` in the swarm's `objects:` list — the engine
   supervises it and tears the listener down deterministically. Zero host code needed
   to boot (`DataSource.Null` default).
2. **Boot-script**: vendor it (e.g. a git submodule at `vendor/genswarms-dashboard`)
   and call `GenswarmsDashboard.start/1` at boot, with the pinned require order.

Vendoring instructions, the require order, the object config, and the `DataSource`
contract: [`backend/README.md`](backend/README.md). The swarmidx package is
`kind: handler` with `dir: backend` — the frontend is an external client app,
deliberately not part of the package.

```sh
cd backend && mix test   # standalone suite; engine calls are stubbed
```
