defmodule GenswarmsDashboard.Config do
  @moduledoc """
  Stash for the host-injected runtime config. The library never reads env vars;
  the host app reads env and calls `GenswarmsDashboard.start/1`, which `put/1`s the
  resolved map here. Stored in Application env under `:genswarms_dashboard`.
  """

  @app :genswarms_dashboard

  @spec put(map()) :: :ok
  def put(%{} = config), do: Application.put_env(@app, :config, config)

  @spec get(atom(), any()) :: any()
  def get(key, default \\ nil) do
    @app |> Application.get_env(:config, %{}) |> Map.get(key, default)
  end
end
