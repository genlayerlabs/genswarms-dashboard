defmodule GenswarmsDashboard.ConfigRouteTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias GenswarmsDashboard.Config

  @opts GenswarmsDashboard.Plug.init([])

  setup do
    Config.put(%{
      swarm: "fix",
      data_source: GenswarmsDashboard.FixtureDataSource,
      token: nil
    })

    on_exit(fn ->
      Application.delete_env(:genswarms_dashboard, :config)
      Application.delete_env(:genswarms_dashboard, :stub_full_config)
    end)
  end

  defp get_config(swarm \\ "fix") do
    conn = conn(:get, "/api/swarms/#{swarm}/config") |> GenswarmsDashboard.Plug.call(@opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "returns redacted per-object config from the engine's effective config" do
    Application.put_env(:genswarms_dashboard, :stub_full_config, %{
      objects: [
        # a handler with no discoverable schema -> names only
        %{name: :mystery, handler: Mystery.Handler, config: %{secret_ish: "value"}}
      ]
    })

    {200, body} = get_config()

    assert body["swarm"] == "fix"
    assert body["source"] == "engine"
    [obj] = body["objects"]
    assert obj["name"] == "mystery"
    assert obj["has_schema"] == false
    [row] = obj["config"]
    assert row["key"] == "secret_ish"
    assert row["value"] == nil
    assert row["in_schema"] == false
  end

  test "unknown swarm -> 404; engine down -> 503" do
    Application.put_env(:genswarms_dashboard, :stub_full_config, fn _ -> {:error, :not_found} end)
    assert {404, %{"error" => "swarm_not_found"}} = get_config("nope")

    Application.put_env(:genswarms_dashboard, :stub_full_config, fn _ -> {:error, :down} end)
    assert {503, %{"error" => "swarm_config_unavailable"}} = get_config()
  end

  test "config rows carry the pinned key set (wire contract)" do
    Application.put_env(:genswarms_dashboard, :stub_full_config, %{
      objects: [%{name: :o, handler: H, config: %{k: 1}}]
    })

    {200, body} = get_config()
    [%{"config" => [row]}] = body["objects"]

    assert Map.keys(row) |> Enum.sort() ==
             ~w(description in_schema key mutable secret value)
  end
end
