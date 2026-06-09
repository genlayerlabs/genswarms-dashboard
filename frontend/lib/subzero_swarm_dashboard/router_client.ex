defmodule SubzeroSwarmDashboard.RouterClient do
  @moduledoc """
  Read-only client for the LLM router's usage endpoint. Usage is optional: when the
  endpoint is unconfigured or absent (404), returns `{:unavailable, reason}` so the
  dashboard degrades to "Usage unavailable" (spec §12).
  """

  @callback usage(opts :: map()) :: {:ok, map()} | {:unavailable, term()}

  defp impl, do: Application.fetch_env!(:subzero_swarm_dashboard, :router_client)

  def usage(opts \\ %{}), do: impl().usage(opts)
end
