# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :subzero_swarm_dashboard,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SubzeroSwarmDashboardWeb.ErrorHTML, json: SubzeroSwarmDashboardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SubzeroSwarmDashboard.PubSub,
  live_view: [signing_salt: "1q9h4P/l"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  subzero_swarm_dashboard: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  subzero_swarm_dashboard: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Read-only clients for the swarm/router (overridden by Mox in test).
config :subzero_swarm_dashboard,
  swarm_client: SubzeroSwarmDashboard.SwarmClient.Http,
  router_client: SubzeroSwarmDashboard.RouterClient.Http

# Pipeline canvas lane map (spec §5.5): the wingston pipeline as DATA, pushed to
# the JS hook once per mount ("pipeline:init"). The flow runs telegram → ingress →
# agent column → sender → back to telegram (the return arc), with LLM-ish services
# above and bookkeeping below. x/y are canvas fractions, r a pixel radius; kind
# "ext" marks endpoints outside the swarm. Agent slots are NOT listed — they are
# dynamic (snapshot pool + events) and stack at `agent_column_x`. `chatter` names
# the nodes whose mutual traffic is background noise (hidden behind the canvas
# chatter toggle); `return_arcs` curve reply legs under the pipeline.
config :subzero_swarm_dashboard, :pipeline_layout, %{
  nodes: [
    %{name: "telegram", x: 0.06, y: 0.50, kind: "ext", r: 15},
    %{name: "ingress", x: 0.21, y: 0.50, kind: "obj", r: 18},
    %{name: "sender", x: 0.76, y: 0.50, kind: "obj", r: 18},
    %{name: "rally", x: 0.21, y: 0.13, kind: "obj", r: 18},
    %{name: "policy", x: 0.38, y: 0.13, kind: "obj", r: 18},
    %{name: "browser", x: 0.57, y: 0.13, kind: "obj", r: 18},
    %{name: "web", x: 0.74, y: 0.13, kind: "ext", r: 14},
    %{name: "roster", x: 0.26, y: 0.87, kind: "obj", r: 18},
    %{name: "commands", x: 0.40, y: 0.87, kind: "obj", r: 18},
    %{name: "cron", x: 0.54, y: 0.87, kind: "obj", r: 18},
    %{name: "metrics", x: 0.68, y: 0.87, kind: "obj", r: 18}
  ],
  agent_column_x: 0.47,
  chatter: ["rally", "policy", "cron", "roster", "metrics"],
  return_arcs: [%{from: "sender", to: "telegram", cx: 0.41, cy: 0.99}],
  # only pool slots belong in the agent column — sample/template agents
  # (conversation_sample) are real swarm members but visual noise on the
  # user-request pipeline. nil/absent ⇒ no filtering.
  agent_pattern: "^wingston_agent_"
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
