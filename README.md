# subzero-swarm-dashboard

A reusable, **read-only** web dashboard for observing a single swarm built on the
[`subzero-swarm`](https://github.com/jmlago/subzero-swarm) runtime. It shows swarm
health, the live agent/object **topology** (agents vs objects), **sessions** and
their transcripts, events, logs, and LLM usage.

Telegram is the first **transport adapter** — the dashboard is transport-agnostic
(sessions carry a `transport` + `transport_ref`). It's a standalone Phoenix
LiveView app that talks to the swarm over **HTTP/WS only** (it never touches the
swarm DB/Store). Design: `docs/superpowers/specs/2026-06-03-subzero-swarm-dashboard-design.md`
in the wingston repo.

## Prerequisite (important)

The swarm's read API **must run inside the swarm's own BEAM** — the dashboard reads
live, node-local state, so a separately-started API server sees nothing. With the
Wingston dev launcher this is already wired:

```elixir
# run_dev_local.exs (in the wingston repo) — starts the endpoint in-process:
{:ok, _} = SubzeroclawSwarm.Application.start_web_server(port: 4000)
```

So bring the swarm up first (`cd vendor/subzero-swarm && mix run ../../run_dev_local.exs`);
its read API listens on `http://127.0.0.1:4000`.

## Toolchain

Elixir 1.18 / OTP 27 (pinned in `.tool-versions` for [mise](https://mise.jdx.dev/)).
`mise install` to match.

## Run (local toolchain)

```bash
mise install            # erlang 27 + elixir 1.18 (first time)
mix setup               # deps + assets
SWARM_API_URL=http://127.0.0.1:4000 SWARM_NAME=wingston mix phx.server
# → http://127.0.0.1:4100
```

## Deploy (Docker)

A self-contained multi-stage `Dockerfile` (mix release) and a `docker-compose.yml`
ship in the repo — build & run, nothing to author:

```bash
cp .env.docker.example .env      # then fill SECRET_KEY_BASE + SWARM_API_TOKEN
docker compose up -d --build     # → http://127.0.0.1:4100 (published on loopback)
```

- `SECRET_KEY_BASE` is required (`mix phx.gen.secret`); `SWARM_API_TOKEN` must equal
  the swarm's `DASHBOARD_API_TOKEN`.
- `SWARM_API_URL` must be reachable **from the container**. The default
  `http://host.docker.internal:4000` (with `extra_hosts: host-gateway`) reaches a
  swarm BEAM running on the host. If the swarm is another compose service, set
  `SWARM_API_URL=http://<swarm-service>:4000` and attach to its network (commented
  block in `docker-compose.yml`).
- The image exposes `4100` and has a `HEALTHCHECK` against the unauthenticated
  `/healthz` endpoint. Assets (incl. the vendored cytoscape) are built and digested
  inside the image.

## Configuration (env)

| Var | Default | Purpose |
|---|---|---|
| `SWARM_API_URL` | `http://127.0.0.1:4000` | Swarm read API base (the in-BEAM endpoint) |
| `SWARM_WS_URL` | derived from `SWARM_API_URL` | WS base for the live event tail |
| `SWARM_NAME` | `wingston` | Which swarm to view |
| `SWARM_API_TOKEN` | — | Read-only bearer/WS token (the swarm's `DASHBOARD_API_TOKEN`) |
| `ROUTER_USAGE_URL` | — | LLM router usage endpoint (e.g. `https://router.ygr.ai/v1/usage`) |
| `ROUTER_API_KEY` | — | Router key (server-side only) |
| `PORT` | `4100` | Dashboard HTTP port (kept off the swarm's 4000) |
| `DASHBOARD_POLL_MS` | `3000` | Snapshot poll interval |
| `DASHBOARD_USER` / `DASHBOARD_PASS` | — | Basic-auth for the UI (active only when both set) |

## Pages

- **Overview / Health** — status, `data_source`, **slot-pool saturation** (LRU
  eviction drops live sessions when full), consumers, usage, connection/co-location banners.
- **Topology** — cytoscape graph; objects (rectangles) vs agents (ellipses), pool
  counter, "show idle" toggle, sortable table fallback.
- **Sessions** + detail — table by session with search (chat/user/session id);
  detail lazily fetches the durable transcript (bodies are never in the snapshot — privacy §8.4).
- **Events** — structured lifecycle events (filterable), from the swarm events endpoint.
- **Usage** — router tokens/cost; degrades to "Usage unavailable" until the router
  exposes `/v1/usage` (spec §9).
- **Logs** — raw per-slot output is ephemeral; viewed per session.

## How it works

`SwarmFeed` polls `/api/swarms/:name/dashboard` every `DASHBOARD_POLL_MS` and
`SwarmFeed.Socket` (Slipstream) joins the swarm's `swarm:<name>` WS channel; both
republish onto one `Phoenix.PubSub` topic (`"feed"`) that LiveViews subscribe to.
A silent-empty guard warns when snapshots report agents but no WS events arrive
(the "API not co-located with the swarm BEAM" failure).

`SwarmClient`/`RouterClient` are behaviour-backed (Mox in tests); the dashboard is
a pure HTTP/WS client.

## Adding a transport

The dashboard is transport-agnostic. Another `subzero-swarm` bot reuses it by
implementing `dashboard/1` on its session-holding object to emit
`%{kind: :sessions, items: [...]}` with the right `transport`/`transport_ref`/`metadata`
(and a durable transcript via `session_history/3`). No dashboard changes needed.

## Production notes

- cytoscape is vendored locally at `priv/static/vendor/cytoscape.min.js` (served via the
  `vendor` static path) — no runtime CDN dependency, so the dashboard works air-gapped.
  To upgrade, replace that file from `unpkg.com/cytoscape@<ver>/dist/cytoscape.min.js`.
- Set `DASHBOARD_USER`/`DASHBOARD_PASS` and `SWARM_API_TOKEN`, and bind to
  localhost/Tailscale. The swarm should also set an explicit WS `check_origin` in prod
  (the read token is the primary gate).

## Toolchain gotcha (apt vs mise OTP)

This project (and the `subzero-swarm` framework) builds cleanly on the **mise** OTP 27
in `.tool-versions` because that source-built Erlang ships the `public_key` ASN.1
headers and the full `ssh` app. On a minimal **apt** Erlang you may hit two unrelated
compile breaks: Phoenix's `mix phx.gen.cert` needs `public_key/include/OTP-PUB-KEY.hrl`
(install `erlang-dev`), and the framework drops `:ssh` from `extra_applications`
(install `erlang-ssh` to restore the SSH backend). Stick to the pinned mise toolchain
and neither bites.
