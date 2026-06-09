defmodule SubzeroSwarmDashboard.SwarmClient do
  @moduledoc """
  Read-only client for the swarm dashboard surface (Plan 1). The concrete impl is
  configured (`:swarm_client`) — `SwarmClient.Http` in prod/dev, a Mox mock in test.
  The dashboard talks HTTP/WS only; it never touches the swarm DB/Store.
  """

  @callback dashboard(swarm :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback session_history(swarm :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback session_logs(swarm :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback events(swarm :: String.t(), opts :: map()) :: {:ok, list()} | {:error, term()}

  defp impl, do: Application.fetch_env!(:subzero_swarm_dashboard, :swarm_client)

  def dashboard(swarm), do: impl().dashboard(swarm)
  def session_history(swarm, session_id), do: impl().session_history(swarm, session_id)
  def session_logs(swarm, session_id), do: impl().session_logs(swarm, session_id)
  def events(swarm, opts \\ %{}), do: impl().events(swarm, opts)
end
