defmodule GenswarmsDashboard do
  @moduledoc """
  Generic read-only dashboard backend for a genswarms swarm. The host app injects all
  app-specific knowledge through `GenswarmsDashboard.DataSource` (and optionally
  `GenswarmsDashboard.EventsSource`) and all runtime config through `start/1` — this
  library reads no env vars and contains no transport specifics.
  """

  alias GenswarmsDashboard.Config

  @doc """
  Start the dashboard endpoint with injected config. Options:

    * `:swarm` (required) — swarm name, e.g. `"wingston"`
    * `:data_source` (required) — module implementing `GenswarmsDashboard.DataSource`
    * `:events_source` — optional module implementing `GenswarmsDashboard.EventsSource`;
      unset/nil ⇒ `GET …/events/feed` answers `source: "unavailable"`
    * `:pubsub_server` (required) — the engine's `Phoenix.PubSub` name (e.g. `Genswarms.PubSub`)
    * `:token` — auth token; nil or "" ⇒ bind 127.0.0.1 + no auth (fail-closed); set ⇒ bind 0.0.0.0 + require it
    * `:port` — string or integer, default 4001
    * `:host` — URL host, default "localhost"
    * `:secret_key_base` — ≥64 bytes for stability across restarts; per-boot random if unset
    * `:data_source_label` — the envelope's `data_source` field, default "genswarms"
    * `:heartbeat_ms` — WS heartbeat interval, default 5000

  Lifecycle: links the endpoint to the caller; there is NO supervisor and no restart on
  crash. Suits a boot-script host that wraps the call in try/rescue (a dashboard failure
  must not take the host down). To supervise instead, put the injected config in place
  and start `GenswarmsDashboard.Endpoint` as a child spec under your own supervisor.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    # "" behaves like nil: an empty env var must not produce a dead 0.0.0.0 endpoint
    # that 401s everything — it means "no token configured" (loopback bind, no auth).
    token =
      case Keyword.get(opts, :token) do
        "" -> nil
        t -> t
      end

    port = opts |> Keyword.get(:port, 4001) |> to_int(4001)

    Config.put(%{
      swarm: Keyword.fetch!(opts, :swarm),
      data_source: Keyword.fetch!(opts, :data_source),
      events_source: Keyword.get(opts, :events_source),
      pubsub_server: Keyword.fetch!(opts, :pubsub_server),
      token: token,
      port: port,
      data_source_label: Keyword.get(opts, :data_source_label, "genswarms"),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000)
    })

    Application.put_env(:genswarms_dashboard, GenswarmsDashboard.Endpoint, endpoint_config(opts, token, port))
    GenswarmsDashboard.Endpoint.start_link([])
  end

  @doc "Human-readable description of where/how the listener is bound. Call after start/1."
  def describe do
    port = Config.get(:port)

    if Config.get(:token),
      do: "http://0.0.0.0:#{port} (token REQUIRED — Bearer header or ?token=)",
      else: "http://127.0.0.1:#{port} (loopback only — no token)"
  end

  @doc false
  # Public for the bind fail-closed test; not part of the host-facing API.
  def endpoint_config(opts, token, port) do
    ip = if token, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

    [
      adapter: Bandit.PhoenixAdapter,
      http: [ip: ip, port: port],
      url: [host: Keyword.get(opts, :host) || "localhost", port: port],
      server: true,
      check_origin: false,
      pubsub_server: Keyword.fetch!(opts, :pubsub_server),
      secret_key_base: secret_key_base(Keyword.get(opts, :secret_key_base))
    ]
  end

  defp secret_key_base(s) when is_binary(s) and byte_size(s) >= 64, do: s
  # no persistent sessions ride this endpoint, so a per-boot key is acceptable; the host
  # sets DASHBOARD_SECRET_KEY_BASE for stability across restarts in prod.
  defp secret_key_base(_), do: :crypto.strong_rand_bytes(48) |> Base.encode64()

  defp to_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
