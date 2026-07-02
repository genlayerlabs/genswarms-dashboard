---
name: genswarms-dashboard-use
description: >-
  Wire the genswarms-dashboard into a swarm: the Objects.Dashboard handler
  (declared in the swarm's objects list), token/bind fail-closed semantics,
  DataSource/EventsSource injection, and pointing the LiveView frontend at the
  backend. Use when adding observability to a swarm, packaging it via swarmidx,
  or debugging "dashboard 401s everything / binds loopback only / sessions list
  empty". This is the importer's guide — for the wire contract and vendoring
  internals read backend/README.md.
---

# genswarms-dashboard — using the package

Read-only observability for a genswarms swarm, two halves: `backend/` (HTTP
read-API + WS live-feed relay, runs INSIDE the orchestrator BEAM) and
`frontend/` (7-page LiveView UI, a separate process/machine). The swarmidx
package (`kind: handler`, `dir: backend`) is the BACKEND — the frontend is an
external client app, not slot content.

## The object form (preferred)

Declare it as data in the swarm definition — the engine supervises it, and
teardown stops the listener:

```elixir
objects: [
  %{
    name: :dashboard,
    handler: GenswarmsDashboard.Objects.Dashboard,
    config: %{
      swarm: "my-swarm",                     # required
      port: 4001,
      token: System.get_env("GENSWARMS_DASHBOARD_TOKEN"),
      data_source: MyApp.DashboardSource,    # default: DataSource.Null
      events_source: MyApp.EventFeedSource,  # optional
      pubsub_server: Genswarms.PubSub        # default
    }
  }
]
```

- **Zero host code boots**: without `data_source` it runs on `DataSource.Null`
  — overview/topology/events/logs pages work from engine data; the sessions
  list is just empty. Add a `DataSource` when you have a durable store.
- Module refs as atoms or strings (`"MyApp.DashboardSource"` from JSON IR);
  strings resolve with `to_existing_atom` — unknown module fails init closed.
- `{"action":"status"}` routed to the object answers listener address +
  liveness (usable from swarm-msg for smoke checks).
- The legacy form (`GenswarmsDashboard.start/1` from a boot script +
  `Code.require_file` vendoring with the pinned order) still works — see
  backend/README.md. The object form is the same engine BEAM, supervised.

## Token / bind semantics (fail-closed)

- **No token (nil or "")** → binds `127.0.0.1`, no auth. An empty env var
  means "not configured", never a dead 0.0.0.0 endpoint that 401s everything.
- **Token set** → binds `0.0.0.0` and REQUIRES it (Bearer header or `?token=`).
- So: "dashboard only answers on localhost" = you didn't set a token — that's
  the guard, not a bug. Set `GENSWARMS_DASHBOARD_TOKEN` to expose it.
- Set `DASHBOARD_SECRET_KEY_BASE` (≥64 bytes) in prod for stability across
  restarts; otherwise a per-boot random key is used (fine — no sessions).

## The frontend

Runs anywhere with HTTP/WS reach to the backend:

```sh
cd frontend
SWARM_API_URL=http://HOST:4001 SWARM_WS_URL=http://HOST:4001 \
SWARM_NAME=my-swarm SWARM_API_TOKEN=… PORT=4200 mix phx.server
```

## Gotchas

- **One dashboard object per BEAM** — the runtime config is a single slot and
  the endpoint module is global. A second object clobbers the first.
- The engine BEAM must provide the runtime modules (`Genswarms.SwarmManager`,
  `Routing.Router`, `Observability.LogStore`, `Agents.AgentServer`) and a
  running `Phoenix.PubSub` — true inside any genswarms host app; NOT true in
  a bare IEx. Standalone `mix test` in backend/ stubs them.
- Sessions list empty with a real store → your `DataSource.snapshot/1` rows
  need unique `session_id`s; live state is overlaid by the aggregate, don't
  precompute it.
- The wire contract (routes + envelope + WS event names) is pinned by the
  backend's golden contract test — frontend and backend versions must agree
  on it; bump them together.
