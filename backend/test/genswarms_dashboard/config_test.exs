defmodule GenswarmsDashboard.ConfigTest do
  use ExUnit.Case, async: false
  alias GenswarmsDashboard.Config

  setup do
    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :config) end)
  end

  test "put/get roundtrip" do
    Config.put(%{swarm: "w", token: "t"})
    assert Config.get(:swarm) == "w"
    assert Config.get(:token) == "t"
  end

  test "get returns the default when unset or key missing" do
    assert Config.get(:token) == nil
    assert Config.get(:data_source_label, "genswarms") == "genswarms"
    Config.put(%{swarm: "w"})
    assert Config.get(:heartbeat_ms, 5_000) == 5_000
  end
end
