defmodule SubzeroSwarmDashboard.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SubzeroSwarmDashboardWeb.Telemetry,
        {DNSCluster,
         query: Application.get_env(:subzero_swarm_dashboard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SubzeroSwarmDashboard.PubSub}
      ] ++
        feed_children() ++
        [
          # Start to serve requests, typically the last entry
          SubzeroSwarmDashboardWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SubzeroSwarmDashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The polling feeds + WS client. Disabled in test (config :start_feed false) so the
  # Mox swarm client isn't called without expectations.
  defp feed_children do
    if Application.get_env(:subzero_swarm_dashboard, :start_feed, true) do
      [
        SubzeroSwarmDashboard.SwarmFeed,
        SubzeroSwarmDashboard.SwarmFeed.Socket,
        SubzeroSwarmDashboard.EventsFeed
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SubzeroSwarmDashboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
