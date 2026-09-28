defmodule SubzeroSwarmDashboard.RouterClient.Http do
  @moduledoc "Req-based HTTP impl of `SubzeroSwarmDashboard.RouterClient`."
  @behaviour SubzeroSwarmDashboard.RouterClient

  @impl true
  def usage(opts) do
    url = Application.get_env(:subzero_swarm_dashboard, :router_usage_url)
    key = Application.get_env(:subzero_swarm_dashboard, :router_api_key)

    if url in [nil, ""] or key in [nil, ""] do
      {:unavailable, :not_configured}
    else
      params = Map.take(opts, [:since, :until, :bucket])

      req_opts =
        [
          params: params,
          headers: [{"authorization", "Bearer #{key}"}],
          receive_timeout: 8_000,
          retry: false,
          # Cached pages must not retain discarded response fields through string references.
          decode_json: [strings: :copy]
        ] ++
          Application.get_env(:subzero_swarm_dashboard, :req_options, [])

      case Req.get(url, req_opts) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: 200}} -> {:unavailable, :invalid_response}
        {:ok, %{status: 404}} -> {:unavailable, :not_found}
        {:ok, %{status: s}} -> {:unavailable, {:http, s}}
        {:error, reason} -> {:unavailable, reason}
      end
    end
  end
end
