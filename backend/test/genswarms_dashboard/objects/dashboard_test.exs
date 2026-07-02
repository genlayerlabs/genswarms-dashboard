defmodule GenswarmsDashboard.Objects.DashboardTest do
  use ExUnit.Case, async: false

  alias GenswarmsDashboard.Objects.Dashboard

  setup do
    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :config) end)
  end

  defp base_config(port) do
    %{
      swarm: "fix",
      port: port,
      pubsub_server: GenswarmsDashboard.TestPubSub,
      data_source: GenswarmsDashboard.FixtureDataSource
    }
  end

  test "init/1 boots the endpoint from pure-data config and terminate/2 stops it" do
    {:ok, state} = Dashboard.init(base_config(4098))
    assert is_pid(state.endpoint) and Process.alive?(state.endpoint)
    assert GenswarmsDashboard.describe() =~ "127.0.0.1:4098"

    # the listener actually answers (unknown route -> the plug's JSON 404)
    Process.sleep(300)
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", 4098, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(s, "GET /nope HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    {:ok, resp} = :gen_tcp.recv(s, 0, 5_000)
    :gen_tcp.close(s)
    assert resp =~ " 404 "

    assert :ok = Dashboard.terminate(:normal, state)
    refute Process.alive?(state.endpoint)
  end

  test "init/1 without swarm fails closed" do
    assert {:error, :missing_swarm} = Dashboard.init(%{port: 4099})
    assert {:error, :config_must_be_a_map} = Dashboard.init(nil)
  end

  test "init/1 resolves module refs from strings (JSON IR path) without minting atoms" do
    config = %{
      base_config(4099)
      | data_source: "GenswarmsDashboard.FixtureDataSource",
        pubsub_server: "GenswarmsDashboard.TestPubSub"
    }

    {:ok, state} = Dashboard.init(config)
    on_exit(fn -> Dashboard.terminate(:normal, state) end)
    assert state.data_source == GenswarmsDashboard.FixtureDataSource

    assert {:error, {:unknown_module, _}} =
             Dashboard.init(%{base_config(4099) | data_source: "No.Such.Module"})
  end

  test "defaults: DataSource.Null needs zero host code and answers the contract shapes" do
    assert %{sessions: [], extensions: %{}} = GenswarmsDashboard.DataSource.Null.snapshot("s")
    assert :unavailable = GenswarmsDashboard.DataSource.Null.session_history("cid", 5)

    assert %{assigned: %{}, last_seen: %{}, leased: 0, size: 0} =
             GenswarmsDashboard.DataSource.Null.pool_snapshot("s")
  end

  test "handle_message/3 answers status and fails legible on unknown input" do
    {:ok, state} = Dashboard.init(base_config(4100))
    on_exit(fn -> Dashboard.terminate(:normal, state) end)

    {:reply, json, ^state} = Dashboard.handle_message(:agent, ~s({"action":"status"}), state)
    assert %{"ok" => true, "swarm" => "fix", "endpoint_alive" => true} = Jason.decode!(json)

    {:reply, json, ^state} = Dashboard.handle_message(:agent, ~s({"action":"nope"}), state)
    assert %{"ok" => false, "error" => "unknown_action"} = Jason.decode!(json)

    {:reply, json, ^state} = Dashboard.handle_message(:agent, "not json", state)
    assert %{"ok" => false, "error" => "bad_json"} = Jason.decode!(json)
  end

  test "interface/0 documents the status action" do
    assert %{status: %{input: _, output: _}} = Dashboard.interface()
  end
end
