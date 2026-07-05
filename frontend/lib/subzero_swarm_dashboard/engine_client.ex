defmodule SubzeroSwarmDashboard.EngineClient do
  @moduledoc """
  Write client for the genswarms ENGINE REST API — the configurator's only
  mutation path. Distinct from `SwarmClient` on purpose: the dashboard
  backend surface stays read-only; writes go to the engine, which applies
  its own auth (`GENSWARMS_API_TOKEN`) and the config_schema op gate
  server-side (this client is a convenience, never the authority).

  Fail-closed: with `CONFIGURATOR_ENGINE_URL` unset, `enabled?/0` is false —
  the Config page renders read-only and no mutation call can be built.
  """

  @doc "Is the write surface configured at all?"
  def enabled? do
    is_binary(url()) and url() != ""
  end

  @doc """
  PATCH /api/swarms/:swarm/objects/:object/config with `%{"config" => patch}`.
  The patch is string-keyed JSON; the ENGINE gate (config_schema x-mutable)
  decides what is allowed.
  """
  def patch_object_config(swarm, object, patch) when is_map(patch) do
    if enabled?() do
      req()
      |> Req.patch(
        url: "/api/swarms/#{swarm}/objects/#{object}/config",
        json: %{config: patch}
      )
      |> handle()
    else
      {:error, :configurator_disabled}
    end
  end

  @doc "GET /api/swarms/:swarm/overlay — the mutation audit trail."
  def overlay(swarm) do
    if enabled?() do
      req() |> Req.get(url: "/api/swarms/#{swarm}/overlay") |> handle()
    else
      {:error, :configurator_disabled}
    end
  end

  defp handle({:ok, %Req.Response{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %Req.Response{status: s, body: body}}), do: {:error, {s, body}}
  defp handle({:error, reason}), do: {:error, reason}

  defp req do
    headers = if token(), do: [{"authorization", "Bearer #{token()}"}], else: []
    Req.new(base_url: url(), headers: headers, receive_timeout: 10_000)
  end

  defp url, do: Application.get_env(:subzero_swarm_dashboard, :configurator_engine_url)
  defp token, do: Application.get_env(:subzero_swarm_dashboard, :configurator_engine_token)
end
