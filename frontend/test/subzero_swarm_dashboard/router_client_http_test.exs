defmodule SubzeroSwarmDashboard.RouterClient.HttpTest do
  # async: false — mutates the router_usage_url/router_api_key app env.
  use ExUnit.Case, async: false
  alias SubzeroSwarmDashboard.RouterClient.Http

  setup do
    prev_url = Application.get_env(:subzero_swarm_dashboard, :router_usage_url)
    prev_key = Application.get_env(:subzero_swarm_dashboard, :router_api_key)

    on_exit(fn ->
      Application.put_env(:subzero_swarm_dashboard, :router_usage_url, prev_url)
      Application.put_env(:subzero_swarm_dashboard, :router_api_key, prev_key)
    end)

    :ok
  end

  defp configure do
    Application.put_env(:subzero_swarm_dashboard, :router_usage_url, "http://router.test/v1/usage")
    Application.put_env(:subzero_swarm_dashboard, :router_api_key, "k")
  end

  test "unconfigured → {:unavailable, :not_configured} (no request)" do
    Application.delete_env(:subzero_swarm_dashboard, :router_usage_url)
    assert {:unavailable, :not_configured} = Http.usage(%{})
  end

  test "200 → {:ok, body}" do
    configure()

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Req.Test.json(conn, %{"totals" => %{"requests" => 3}})
    end)

    assert {:ok, %{"totals" => %{"requests" => 3}}} = Http.usage(%{bucket: "day"})
  end

  test "404 → {:unavailable, :not_found}" do
    configure()
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:unavailable, :not_found} = Http.usage(%{})
  end
end
