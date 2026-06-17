defmodule GenswarmsDashboard.Plug do
  @moduledoc """
  Read-only HTTP surface for the dashboard. Routes and JSON shapes are PINNED — the
  frontend (subzero-swarm-dashboard) reads them as-is (see the golden contract test).

  Fail-closed auth, token injected via `GenswarmsDashboard.Config` (never env):
    * token nil  → the endpoint binds loopback (see `GenswarmsDashboard.start/1`); locality is the gate.
    * token set  → every request needs `Authorization: Bearer <t>` OR `?token=<t>`.

  App-specific data comes from the configured `GenswarmsDashboard.DataSource` and the
  optional `GenswarmsDashboard.EventsSource` (display event feed); events and logs read
  the genswarms engine directly (public read APIs, same BEAM).
  """
  use Plug.Router

  alias GenswarmsDashboard.{Aggregate, Config}

  plug(:put_cors)
  plug(:auth)
  plug(:match)
  plug(:dispatch)

  # GET /api/swarms/:name/dashboard  → the aggregate envelope
  get "/api/swarms/:name/dashboard" do
    case Aggregate.build(name) do
      {:ok, data} -> json(conn, 200, data)
      {:error, :not_found} -> json(conn, 404, %{error: "swarm_not_found"})
    end
  end

  # GET /api/swarms/:name/sessions/:session_id/history  → durable transcript (DataSource)
  get "/api/swarms/:_name/sessions/:session_id/history" do
    max = conn |> fetch_query_params() |> Map.get(:query_params) |> Map.get("max_turns", "40") |> to_int(40)

    case Config.get(:data_source).session_history(session_id, max) do
      {:ok, turns} -> json(conn, 200, %{session_id: session_id, turns: turns, source: "store"})
      :unavailable -> json(conn, 200, %{session_id: session_id, turns: [], source: "unavailable"})
    end
  end

  # GET /api/swarms/:name/sessions/:session_id/logs  → the CURRENTLY-leased agent slot's logs.
  # Slot resolved from the LIVE pool_snapshot only (never durable — slots are recycled), so a
  # session that isn't leased right now returns "unavailable" (correct, no cross-conversation bleed).
  get "/api/swarms/:name/sessions/:session_id/logs" do
    case slot_logs(name, session_id) do
      {:ok, entries} -> json(conn, 200, %{session_id: session_id, logs: entries, source: "slot"})
      :unavailable -> json(conn, 200, %{session_id: session_id, logs: [], source: "unavailable"})
    end
  end

  # GET /api/swarms/:name/sessions/:session_id/skills  → the skills dir an agent slot is
  # primed with — the exact .md files subzeroclaw concatenates into its system prompt at
  # session start. Read from disk via the engine's get_skills_content (same BEAM), NOT
  # from the session log, so no upstream logging/parsing is needed; the tradeoff is this
  # shows the dir's CURRENT contents, not a verbatim record of session start (skills can
  # be updated mid-session via the engine API).
  #
  # Unlike /logs this does NOT require the session to be leased: logs are per-conversation
  # (a recycled slot's log would bleed someone else's session), but skills are how the
  # pool's agents are primed — and sessions are mostly inspected AFTER the slot was
  # recycled, exactly when a leased-only rule would hide them. source: "slot" (this
  # session's leased agent) | "pool" (another live agent) | "unavailable".
  get "/api/swarms/:name/sessions/:session_id/skills" do
    case session_skills(name, session_id) do
      {:ok, skills, source} -> json(conn, 200, %{session_id: session_id, skills: skills, source: source})
      :unavailable -> json(conn, 200, %{session_id: session_id, skills: [], source: "unavailable"})
    end
  end

  # GET /api/swarms/:name/events  → the IN-NODE LogStore (read-only, public LogStore.query/1).
  # NOT the SQLite EventStore: that durable store is populated by the daemon/CLI path and is
  # empty in an embedded single-BEAM orchestrator. LogStore (ETS) holds this node's live events.
  get "/api/swarms/:name/events" do
    qp = conn |> fetch_query_params() |> Map.get(:query_params)

    events =
      name
      |> events_query(qp)
      |> Genswarms.Observability.LogStore.query()
      |> Enum.map(&format_event/1)

    json(conn, 200, %{events: events, count: length(events), swarm: name})
  end

  # GET /api/swarms/:name/events/feed  → cursor read of the host's display event feed
  # (the optional EventsSource — host-injected like DataSource). Distinct from /events
  # above, which stays the engine-raw LogStore surface. This route relays {events, seq}
  # verbatim and never interprets an event kind; the cursor semantics are pinned in the
  # EventsSource @doc. The host impl may clamp limit tighter than @int_cap.
  get "/api/swarms/:_name/events/feed" do
    qp = conn |> fetch_query_params() |> Map.get(:query_params)
    # since is a CURSOR, not a size: lifetime seqs legitimately exceed @int_cap, and a
    # clamped cursor would re-deliver every event above the cap forever. Uncapped parse.
    since = qp |> Map.get("since") |> to_cursor()
    limit = qp |> Map.get("limit") |> to_int(500)

    case feed_events(since, limit) do
      %{events: events, seq: seq} -> json(conn, 200, %{events: events, seq: seq, source: "feed"})
      :unavailable -> json(conn, 200, %{events: [], seq: 0, source: "unavailable"})
    end
  end

  # CORS preflight for the browser UI (read-only GETs from another origin/port).
  # NOTE: this sits AFTER :auth, so preflight is token-gated too. Intentional: the real
  # frontend is a server-side Phoenix app sending the header — no browser preflight path.
  options _ do
    conn |> put_resp_header("access-control-allow-methods", "GET, OPTIONS") |> send_resp(204, "")
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  # ── plugs ────────────────────────────────────────────────────────────────────
  defp put_cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
  end

  # No token ⇒ the listener is loopback-only (locality IS the auth). Token ⇒ require it via
  # EITHER `Authorization: Bearer <t>` (apps) OR `?token=<t>` (browser tabs can't set headers;
  # the query form leaks into URLs/history — apps should prefer the header).
  defp auth(conn, _opts) do
    case Config.get(:token) do
      nil ->
        conn

      token ->
        conn = Plug.Conn.fetch_query_params(conn)
        provided = bearer(conn) || conn.query_params["token"]

        if is_binary(provided) and provided != "" and Plug.Crypto.secure_compare(provided, token) do
          conn
        else
          conn |> json(401, %{error: "unauthorized"}) |> halt()
        end
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> t
      _ -> nil
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Positive-int parse with a generous cap: query params size result sets / time windows
  # (limit, max_turns, minutes) — never let an attacker-sized integer reach the stores.
  @int_cap 10_000
  defp to_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n > 0 -> min(n, @int_cap)
      _ -> default
    end
  end

  # Non-negative cursor parse, deliberately uncapped (see the events/feed route).
  defp to_cursor(s) do
    case Integer.parse(to_string(s)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  # ── logs (live slot only) ──────────────────────────────────────────────────────
  defp slot_logs(swarm, cid) do
    case live_slot(swarm, cid) do
      nil ->
        :unavailable

      slot ->
        try do
          entries = Genswarms.Agents.AgentServer.get_logs(swarm, slot) || []
          {:ok, Enum.map(entries, &rename_log_file/1)}
        rescue
          _ -> :unavailable
        catch
          :exit, _ -> :unavailable
        end
    end
  end

  defp session_skills(swarm, cid) do
    cond do
      slot = live_slot(swarm, cid) -> read_skills(swarm, slot, "slot")
      slot = any_live_agent(swarm) -> read_skills(swarm, slot, "pool")
      true -> :unavailable
    end
  end

  # Projected to name+content only — get_skills_content also returns the host
  # filesystem :path, which must not reach the wire.
  defp read_skills(swarm, slot, source) do
    skills = Genswarms.Agents.AgentServer.get_skills_content(swarm, slot) || []
    {:ok, Enum.map(skills, fn s -> %{name: s[:name], content: s[:content]} end), source}
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # Any currently-live agent slot: one leased to some other session (pool snapshot),
  # else any agent the swarm reports. Used for skills ONLY — never for logs, where a
  # foreign slot would bleed another conversation.
  defp any_live_agent(swarm) do
    pool_agent =
      case Config.get(:data_source) do
        nil ->
          nil

        ds ->
          case ds.pool_snapshot(swarm) do
            %{assigned: assigned} when map_size(assigned) > 0 ->
              assigned |> Map.values() |> Enum.find(&is_atom/1)

            _ ->
              nil
          end
      end

    pool_agent || swarm_status_agent(swarm)
  end

  # SwarmManager.status is a GenServer.call (5s) that can time out under docker
  # latency; guard the exit like the sibling read paths (logs/skills) so a slow
  # engine degrades this read to :unavailable instead of crashing the API to a 500.
  defp swarm_status_agent(swarm) do
    case Genswarms.SwarmManager.status(swarm) do
      {:ok, %{agents: [a | _]}} -> a[:name]
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp live_slot(swarm, cid) do
    case Config.get(:data_source) do
      nil ->
        nil

      ds ->
        case ds.pool_snapshot(swarm) do
          %{assigned: assigned} ->
            case Map.get(assigned, cid) do
              slot when is_atom(slot) and not is_nil(slot) -> slot
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  # The per-entry session_id from AgentServer logs is the log filename, not a session id.
  defp rename_log_file(%{"session_id" => f} = e), do: e |> Map.delete("session_id") |> Map.put("log_file", f)
  defp rename_log_file(%{session_id: f} = e), do: e |> Map.delete(:session_id) |> Map.put(:log_file, f)
  defp rename_log_file(e), do: e

  # ── events (mirror of the engine's EventsController query/format) ──────────────
  defp events_query(swarm, qp) do
    opts = [swarm: swarm, limit: to_int(Map.get(qp, "limit"), 100)]

    opts =
      case to_int(Map.get(qp, "minutes"), nil) do
        nil -> opts
        m -> Keyword.put(opts, :minutes, m)
      end

    opts
    |> maybe_atom(:level, Map.get(qp, "level"))
    |> maybe_atom(:category, normalize_category(Map.get(qp, "category")))
    |> maybe_atom(:agent, Map.get(qp, "agent"))
  end

  # The dashboard's filter dropdown offers "router"; events are stored as category "routing".
  defp normalize_category("router"), do: "routing"
  defp normalize_category(c), do: c

  # NEVER String.to_atom on request input. to_existing_atom + rescue: an unknown filter value
  # simply drops the filter (the system's real levels/categories/agents are already interned).
  defp maybe_atom(opts, _key, nil), do: opts
  defp maybe_atom(opts, _key, ""), do: opts

  defp maybe_atom(opts, key, val) do
    Keyword.put(opts, key, String.to_existing_atom(val))
  rescue
    ArgumentError -> opts
  end

  defp format_event(e) do
    %{
      id: e.id,
      timestamp: format_ts(e.timestamp),
      level: e.level,
      category: e.category,
      swarm: e.swarm,
      agent: e.agent,
      event_type: e.event_type,
      message: e.message,
      metadata: e.metadata
    }
  end

  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(ts) when is_binary(ts), do: ts
  defp format_ts(ts), do: inspect(ts)

  # ── events feed (host EventsSource, cursor read) ────────────────────────────────
  # No source configured ⇒ unavailable, same fail-soft posture as history/logs/skills.
  # The call is wrapped because a feed crash must not 500 the dashboard.
  defp feed_events(since, limit) do
    case Config.get(:events_source) do
      nil ->
        :unavailable

      source ->
        try do
          source.events_since(since, limit)
        rescue
          _ -> :unavailable
        catch
          :exit, _ -> :unavailable
        end
    end
  end
end
