defmodule SubzeroSwarmDashboard.RouterClient.Http do
  @moduledoc "Req-based HTTP impl of `SubzeroSwarmDashboard.RouterClient`."
  @behaviour SubzeroSwarmDashboard.RouterClient

  @impl true
  def usage(opts) do
    url = Application.get_env(:subzero_swarm_dashboard, :router_usage_url)
    key = Application.get_env(:subzero_swarm_dashboard, :router_api_key)

    if is_nil(url) or is_nil(key) do
      {:unavailable, :not_configured}
    else
      params = Map.take(opts, [:since, :until, :bucket])

      req_opts =
        [params: params, headers: [{"authorization", "Bearer #{key}"}], receive_timeout: 8_000] ++
          Application.get_env(:subzero_swarm_dashboard, :req_options, [])

      case Req.get(url, req_opts) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: 404}} -> {:unavailable, :not_found}
        {:ok, %{status: s}} -> {:unavailable, {:http, s}}
        {:error, reason} -> {:unavailable, reason}
      end
    end
  end
end
