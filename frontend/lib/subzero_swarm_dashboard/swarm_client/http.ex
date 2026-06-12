defmodule SubzeroSwarmDashboard.SwarmClient.Http do
  @moduledoc "Req-based HTTP impl of `SubzeroSwarmDashboard.SwarmClient`."
  @behaviour SubzeroSwarmDashboard.SwarmClient

  @impl true
  def dashboard(swarm), do: get("/api/swarms/#{swarm}/dashboard")

  @impl true
  def session_history(swarm, session_id),
    do: get("/api/swarms/#{swarm}/sessions/#{session_id}/history")

  @impl true
  def session_logs(swarm, session_id),
    do: get("/api/swarms/#{swarm}/sessions/#{session_id}/logs")

  @impl true
  def session_skills(swarm, session_id),
    do: get("/api/swarms/#{swarm}/sessions/#{session_id}/skills")

  @impl true
  def events(swarm, opts) do
    params = Map.take(opts, [:level, :category, :agent, :minutes, :limit])

    case get("/api/swarms/#{swarm}/events", params) do
      {:ok, %{"events" => events}} -> {:ok, events}
      {:ok, body} when is_list(body) -> {:ok, body}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @impl true
  def events_feed(swarm, since, limit),
    do: get("/api/swarms/#{swarm}/events/feed", %{since: since, limit: limit})

  defp get(path, params \\ %{}) do
    base = Application.fetch_env!(:subzero_swarm_dashboard, :swarm_api_url)
    token = Application.get_env(:subzero_swarm_dashboard, :swarm_api_token)
    headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []

    opts =
      [params: params, headers: headers, receive_timeout: 8_000] ++
        Application.get_env(:subzero_swarm_dashboard, :req_options, [])

    case Req.get(base <> path, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
