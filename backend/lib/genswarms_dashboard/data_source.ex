defmodule GenswarmsDashboard.DataSource do
  @moduledoc "App-specific data the generic dashboard aggregate needs. Implemented by the host app."

  @doc """
  ONE consistent durable read: session rows (WITHOUT live state — the aggregate overlays that)
  plus the app-specific extension blocks, e.g. %{"consumers" => %{count:, items:}, "deliveries" => ...}.
  A single callback so both halves come from the same store snapshot (no skew between
  extensions.consumers and sessions; one SQL pass per request).
  Session rows MAY include `last_activity` (durable) — the aggregate uses it as the fallback
  when the cid is not in the live pool. Zero-vs-nil timestamp shaping is the adapter's job.
  Rows must have unique `session_id`s (duplicates are dropped, first wins); the row list
  order is preserved as the wire `sessions` array order, with pool-only fabricated rows
  appended after.

  Reply health requires a separate `"replies"` extension with `available: true`
  and `items: [%{session_id: cid, status: "sent", at: unix_seconds}]`: the latest
  successful actual reply per session, never a proactive or generic delivery.
  An empty successful read uses `items: []`; failed reads use `available: false`.
  Missing/unavailable evidence displays as unavailable, not answered/unanswered.
  An optional top-level `warnings: [string]` reports unavailable host reads.
  Set `sessions_available: false` if the stored population read is incomplete:
  known/live rows remain visible, but `summary.sessions` is nil. Omission defaults
  to true for legacy hosts. Individual rows outside durable reply tracking may
  set `reply_tracking_available: false` to keep their health unavailable.
  """
  @callback snapshot(swarm :: String.t()) ::
              %{sessions: [map()], extensions: %{optional(String.t()) => map()}}

  @doc """
  Durable transcript for a session id. Turn maps carry `role` + `content`, and
  MAY carry additive optional fields the frontend renders when present:
  `at` (unix seconds), `kind` ("message" | "note" — service rows), `auto`
  (true = bot-initiated send). Hosts that return only role/content keep the
  plain rendering.
  """
  @callback session_history(cid :: String.t(), max_turns :: pos_integer()) ::
              {:ok, [map()]} | :unavailable

  @doc "Current live session->slot pool snapshot (cid => slot atom), with last_seen + counts."
  @callback pool_snapshot(swarm :: String.t()) ::
              %{
                assigned: %{optional(String.t()) => atom()},
                last_seen: %{optional(String.t()) => any()},
                leased: non_neg_integer(),
                size: non_neg_integer()
              }

  @doc """
  OPTIONAL. Base row for a pool-only cid (leased right now, not yet in the durable rows).
  Default: the fully-defaulted generic row (see `GenswarmsDashboard.Aggregate.default_session/1`).
  Hosts whose cids encode transport data (e.g. wingston's `tg:<chat>:<thread>`) override this
  so pool-only sessions keep a populated transport/transport_ref.
  """
  @callback fabricate_session(cid :: String.t()) :: map()
  @optional_callbacks fabricate_session: 1
end
