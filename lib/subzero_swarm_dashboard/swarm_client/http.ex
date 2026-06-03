defmodule SubzeroSwarmDashboard.SwarmClient.Http do
  @moduledoc "Req-based HTTP impl of `SubzeroSwarmDashboard.SwarmClient`."
  @behaviour SubzeroSwarmDashboard.SwarmClient

  @impl true
  def dashboard(swarm), do: get("/api/swarms/#{swarm}/dashboard")

  @impl true
  def session_history(swarm, session_id),
    do: get("/api/swarms/#{swarm}/sessions/#{session_id}/history")

  defp get(path) do
    base = Application.fetch_env!(:subzero_swarm_dashboard, :swarm_api_url)
    token = Application.get_env(:subzero_swarm_dashboard, :swarm_api_token)
    headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []

    case Req.get(base <> path, headers: headers, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
