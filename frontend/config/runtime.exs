import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/subzero_swarm_dashboard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint, server: true
end

config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint,
  # default 4100 so it doesn't clash with the swarm's in-BEAM API on :4000
  http: [port: String.to_integer(System.get_env("PORT", "4100"))]

# Dashboard data sources (the swarm read surface + the LLM router usage endpoint).
config :subzero_swarm_dashboard,
  swarm_api_url: System.get_env("SWARM_API_URL", "http://127.0.0.1:4000"),
  swarm_ws_url: System.get_env("SWARM_WS_URL"),
  swarm_name: System.get_env("SWARM_NAME", "wingston"),
  swarm_api_token: System.get_env("SWARM_API_TOKEN"),
  router_usage_url: System.get_env("ROUTER_USAGE_URL"),
  router_api_key: System.get_env("ROUTER_API_KEY"),
  poll_interval_ms: String.to_integer(System.get_env("DASHBOARD_POLL_MS", "3000")),
  events_poll_ms: String.to_integer(System.get_env("DASHBOARD_EVENTS_POLL_MS", "700")),
  stall_after_ms: String.to_integer(System.get_env("DASHBOARD_STALL_AFTER_MS", "180000")),
  # sensitive gate: user transcripts hidden until revealed unless "shown"
  reveal_transcripts_default: System.get_env("DASHBOARD_TRANSCRIPTS_DEFAULT") == "shown"

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :subzero_swarm_dashboard, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Bind address. Default is all interfaces (IPv6) — unchanged. Set PHX_IP to lock
  # it down when the dashboard is NOT already behind a private network / reverse
  # proxy (it is read-only but exposes session/usage data):
  #   PHX_IP=loopback  (or ::1)  -> IPv6 loopback only
  #   PHX_IP=127.0.0.1           -> IPv4 loopback only
  #   PHX_IP=0.0.0.0             -> all IPv4 interfaces
  bind_ip =
    case System.get_env("PHX_IP") do
      blank when blank in [nil, ""] ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      "loopback" ->
        {0, 0, 0, 0, 0, 0, 0, 1}

      addr ->
        case :inet.parse_address(String.to_charlist(addr)) do
          {:ok, ip} -> ip
          _ -> {0, 0, 0, 0, 0, 0, 0, 0}
        end
    end

  config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint,
    url: [
      host: host,
      port: String.to_integer(System.get_env("PHX_PORT", "443")),
      scheme: System.get_env("PHX_SCHEME", "https")
    ],
    check_origin: false,
    http: [
      # Bind address (see `bind_ip` above; default all-interfaces, PHX_IP overrides).
      ip: bind_ip
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
