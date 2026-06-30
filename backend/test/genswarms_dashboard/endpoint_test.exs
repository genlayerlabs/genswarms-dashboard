defmodule GenswarmsDashboard.EndpointTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :config) end)
  end

  test "endpoint_config is fail-closed: loopback without a token, 0.0.0.0 with one" do
    base = [pubsub_server: GenswarmsDashboard.TestPubSub]
    assert GenswarmsDashboard.endpoint_config(base, nil, 4001)[:http][:ip] == {127, 0, 0, 1}
    assert GenswarmsDashboard.endpoint_config(base, "s3cret", 4001)[:http][:ip] == {0, 0, 0, 0}
  end

  test "start/1 normalizes an empty-string token to nil (loopback, no auth)" do
    {:ok, pid} =
      GenswarmsDashboard.start(
        swarm: "fix",
        data_source: GenswarmsDashboard.FixtureDataSource,
        events_source: GenswarmsDashboard.FixtureEventsSource,
        pubsub_server: GenswarmsDashboard.TestPubSub,
        dashboard_title: "",
        token: "",
        port: "4096"
      )

    on_exit(fn -> stop_endpoint(pid) end)
    assert GenswarmsDashboard.Config.get(:token) == nil
    assert GenswarmsDashboard.Config.get(:dashboard_title) == "Fix"
    assert GenswarmsDashboard.Config.get(:events_source) == GenswarmsDashboard.FixtureEventsSource
    assert GenswarmsDashboard.describe() =~ "127.0.0.1:4096"
  end

  test "start/1 boots the endpoint token-free on loopback: API + WS mounted, unknown route 404" do
    {:ok, pid} =
      GenswarmsDashboard.start(
        swarm: "fix",
        data_source: GenswarmsDashboard.FixtureDataSource,
        pubsub_server: GenswarmsDashboard.TestPubSub,
        token: nil,
        port: "4097"
      )

    on_exit(fn -> stop_endpoint(pid) end)
    Process.sleep(300)

    req = fn path ->
      {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", 4097, [:binary, active: false, packet: :raw])

      :ok =
        :gen_tcp.send(s, "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      {:ok, resp} = :gen_tcp.recv(s, 0, 5_000)
      :gen_tcp.close(s)
      resp
    end

    # no swarm stub running ⇒ swarm_not_found, which proves the route + plug are wired
    assert req.("/api/swarms/fix/dashboard") =~ "swarm_not_found"
    # a plain GET on a mounted socket path is NOT a 404 (Phoenix answers 400/426)
    refute req.("/swarm/websocket") =~ " 404 "
    assert req.("/nope") =~ " 404 "
    assert GenswarmsDashboard.describe() =~ "127.0.0.1:4097"
  end

  # Phoenix endpoint supervisors exit with :shutdown, not :normal, so Supervisor.stop/3
  # raises an (EXIT) shutdown. Use Process.exit + monitor for a clean synchronous teardown.
  defp stop_endpoint(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> :timeout
      end
    end
  end
end
