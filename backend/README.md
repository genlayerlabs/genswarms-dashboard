# genswarms-dashboard

Generic read-only dashboard backend (HTTP read-API + WS live-feed relay) for a genswarms
swarm. Runs inside the host BEAM; vendorable via `Code.require_file`. Contains zero
host-app or transport specifics. The genswarms engine is a **runtime-only** dependency
(remote calls; not in `mix.exs`; tests stub it).

The host app injects all app-specific knowledge through `GenswarmsDashboard.DataSource`
and all runtime config through `GenswarmsDashboard.start/1`.

**Runtime dependencies:** the host BEAM must provide these genswarms engine modules
(the library calls them as plain remote calls): `Genswarms.SwarmManager.status/1`,
`Genswarms.Routing.Router.get_topology/1`, `Genswarms.Observability.LogStore.query/1`,
`Genswarms.Agents.AgentServer.get_logs/2`, plus a running `Phoenix.PubSub` (passed as
`pubsub_server:`). Phoenix/Bandit/Plug/Jason must already be loaded (they are, in the
engine BEAM).

---

## Vendoring / require order

The library is designed to be `Code.require_file`d into the genswarms BEAM (which already
has Phoenix, Bandit, Plug, and Jason loaded). The files must be required in this exact order:

```
vendor/genswarms-dashboard/lib/genswarms_dashboard/config.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/data_source.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/aggregate.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/plug.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/socket.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/channel.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard/endpoint.ex
vendor/genswarms-dashboard/lib/genswarms_dashboard.ex
```

**Why the order matters:** `Plug.Builder` runs a module plug's `init/1` at compile time,
so `plug.ex` and `socket.ex` must be required before `endpoint.ex`. Use an explicit list —
never a glob like `lib/**/*.ex`.

---

## The DataSource contract

Implement `GenswarmsDashboard.DataSource` in the host app and pass the module to
`GenswarmsDashboard.start/1` as `:data_source`.

### Callbacks

```elixir
@callback snapshot(swarm :: String.t()) ::
            %{sessions: [map()],
              extensions: %{optional(String.t()) => map()}}
```

ONE consistent durable read: session rows (WITHOUT live state — the aggregate overlays
that) plus app-specific extension blocks, e.g. `%{"consumers" => %{count:, items:},
"deliveries" => ...}`. A single callback so both halves come from the same store snapshot
(no skew between `extensions.consumers` and `sessions`; one SQL pass per request). Session
rows MAY include `last_activity` (durable) — the aggregate uses it as the fallback when
the cid is not in the live pool. Zero-vs-nil timestamp shaping is the adapter's job.
Row list order is preserved as the wire `sessions` array order; pool-only fabricated rows
are appended after.

```elixir
@callback session_history(cid :: String.t(), max_turns :: pos_integer()) ::
            {:ok, [map()]} | :unavailable
```

Durable transcript for a session id.

```elixir
@callback pool_snapshot(swarm :: String.t()) ::
            %{assigned: %{optional(String.t()) => atom()},
              last_seen: %{optional(String.t()) => any()},
              leased: non_neg_integer(), size: non_neg_integer()}
```

Current live session→slot pool snapshot (`cid => slot atom`), with `last_seen` and counts.
The aggregate derives the `/logs` slot lookup from `pool_snapshot(swarm).assigned[cid]` —
no separate callback.

```elixir
@callback fabricate_session(cid :: String.t()) :: map()
@optional_callbacks fabricate_session: 1
```

**Optional.** Base row for a pool-only cid (leased right now, not yet in the durable
rows). Default: the fully-defaulted generic row (see below). Hosts whose cids encode
transport data override this so pool-only sessions keep a populated `transport` /
`transport_ref`.

### Generic session-row shape

The library works for a swarm with no Telegram transport at all. The aggregate fills any
key the `DataSource` omits, and replaces explicit `nil` for the never-nil keys:

```elixir
%{
  session_id:    cid,          # required
  transport:     "unknown",    # DataSource may set "telegram", etc. NEVER nil.
  transport_ref: %{},          # generic map. Telegram adapter sets %{chat_id, thread_id}. NEVER nil.
  user:          nil,          # opaque to the library
  metadata:      %{},          # generic map. NEVER nil.
  last_activity: nil,          # OPTIONAL durable input from the DataSource — fallback below
  # ── overlaid by the aggregate from pool_snapshot ──
  agent:         slot && to_string(slot),  # nil if not currently leased
  state:         if(leased?, do: "active", else: "idle"),
  last_activity: pool_last_seen[cid] || row.last_activity || nil
}
```

The library never reads a transport-specific key (`chat_id`, `thread_id`, `chat_type`,
`"telegram"`). It only passes through what `DataSource` returns and guarantees the defaults
above, so `transport_ref` is always a valid (possibly empty) map and `transport` is always
a non-nil string.

### `fabricate_session/1` — wire-fidelity rationale

Without an override, a pool-only cid (leased right now but not yet in the durable rows)
gets the fully-defaulted generic row: `transport: "unknown"`, `transport_ref: %{}`. For
hosts whose cids encode transport data (e.g. wingston's `tg:<chat>:<thread>`), that would
blank exactly those values for exactly the sessions that are active right now — a silent
wire-value change. Implementing `fabricate_session/1` lets the host parse the cid and
return a row with `transport: "telegram"` + a populated `transport_ref`, keeping the wire
output byte-identical. The library itself still never reads a transport-specific key.

---

## The wire contract

These MUST NOT change — the frontend (`subzero-swarm-dashboard`) reads them. Pinned by
`test/golden_contract_test.exs`.

### HTTP routes (served by `GenswarmsDashboard.Plug`)

- `GET /api/swarms/:name/dashboard` → the envelope (see below)
- `GET /api/swarms/:name/sessions/:session_id/history` → `%{session_id, turns, source}`
- `GET /api/swarms/:name/sessions/:session_id/logs` → `%{session_id, logs, source}`
- `GET /api/swarms/:name/events` → `%{events, count, swarm}`
- `OPTIONS *` → 204 CORS preflight
- `match _` → 404 `%{error}`

### Dashboard envelope (`GET .../dashboard`)

```
%{swarm, status, uptime_s, generated_at, data_source, warnings: [],
  summary: %{agents, objects, sessions, pool: %{leased, size}},
  nodes: [%{name, type, subtype|state}],
  edges: [%{from, to}],
  sessions: [<session row above>],
  extensions: %{"consumers" => %{count, items}, "deliveries" => %{count, items}}}
```

`data_source` is set via the `:data_source_label` key in `GenswarmsDashboard.start/1`
(config, not a callback); the library defaults it to `"genswarms"` if unset.

### WebSocket (`/swarm/websocket`, channel `swarm:*`)

Pushes: `heartbeat` (5 s default), `agent_status`, `message_routed`, `message_broadcast`,
`agent_added`, `agent_removed`, `topology_changed`, `agent_output`, `swarm_started`,
`swarm_stopped`. No `handle_in` (no write path).

---

## Starting it

Call `GenswarmsDashboard.start/1` after requiring the library files. Options:

- `:swarm` (required) — swarm name
- `:data_source` (required) — module implementing `GenswarmsDashboard.DataSource`
- `:pubsub_server` (required) — the engine's `Phoenix.PubSub` name
- `:token` — auth token (see fail-closed rule below)
- `:port` — string or integer, default `4001`
- `:host` — URL host, default `"localhost"` (URL hint only — the actual bind address is
  controlled by `:token`: loopback without one, `0.0.0.0` with one)
- `:secret_key_base` — ≥64 bytes for stability across restarts; per-boot random if unset
- `:data_source_label` — the envelope's `data_source` field, default `"genswarms"`
- `:heartbeat_ms` — WS heartbeat interval, default `5000`

Example (wingston):

```elixir
GenswarmsDashboard.start(
  swarm:             "wingston",
  data_source:       Wingston.DashboardSource,
  data_source_label: "host_sql",
  token:             System.get_env("DASHBOARD_API_TOKEN"),
  port:              (System.get_env("DASHBOARD_PORT") || "4001"),
  host:              System.get_env("DASHBOARD_HOST") || "localhost",
  secret_key_base:   System.get_env("DASHBOARD_SECRET_KEY_BASE"),
  pubsub_server:     Genswarms.PubSub
)
```

### Fail-closed rule

- `:token` nil or `""` → bind `127.0.0.1`, no auth required (locality is the gate)
- `:token` set → bind `0.0.0.0` and require it: `Authorization: Bearer <token>` or
  `?token=<token>` on HTTP; `x-dashboard-token` header, `Authorization: Bearer`, or
  `?token=` on WS. Compared with `Plug.Crypto.secure_compare` (constant time).

An empty env var (`DASHBOARD_API_TOKEN=""`) is treated as nil — it must not produce a
dead `0.0.0.0` endpoint that 401s everything.

### Lifecycle

`start/1` links the endpoint to the caller. There is no supervisor and no restart on
crash. This suits a boot-script host that wraps the call in `try/rescue` (a dashboard
failure must not take the host down). To supervise instead, put the injected config in
place via `Config.put/1` and `Application.put_env/3`, then start
`GenswarmsDashboard.Endpoint` as a child spec under your own supervisor.

---

## Running tests

```bash
mix test
```

Engine calls (`Genswarms.SwarmManager`, `Genswarms.Routing.Router`,
`Genswarms.Observability.LogStore`, `Genswarms.Agents.AgentServer`) are stubbed in
`test/support/genswarms_stubs.ex` — no genswarms dependency needed. Tests steer the stubs
via `Application.put_env/3` under `:genswarms_dashboard`. Because the stubs are global
Application env, most tests run `async: false`.
