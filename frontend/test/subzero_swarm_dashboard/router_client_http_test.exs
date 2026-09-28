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
    Application.put_env(
      :subzero_swarm_dashboard,
      :router_usage_url,
      "http://router.test/v1/usage"
    )

    Application.put_env(:subzero_swarm_dashboard, :router_api_key, "k")
  end

  test "unconfigured → {:unavailable, :not_configured} (no request)" do
    Application.delete_env(:subzero_swarm_dashboard, :router_usage_url)
    assert {:unavailable, :not_configured} = Http.usage(%{})
  end

  test "blank URL or key → {:unavailable, :not_configured} (no request)" do
    for {url, key} <- [{"", "k"}, {"http://router.test/v1/usage", ""}] do
      Application.put_env(:subzero_swarm_dashboard, :router_usage_url, url)
      Application.put_env(:subzero_swarm_dashboard, :router_api_key, key)

      assert {:unavailable, :not_configured} = Http.usage(%{})
    end
  end

  test "200 → {:ok, body}" do
    configure()

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Req.Test.json(conn, %{"totals" => %{"requests" => 3}})
    end)

    assert {:ok, %{"totals" => %{"requests" => 3}}} = Http.usage(%{bucket: "day"})
  end

  test "a cached usage page does not retain the discarded HTTP response buffer" do
    configure()
    model = String.duplicate("synthetic-model-", 8)
    cache = SubzeroSwarmDashboard.RouterUsageCache
    on_exit(fn -> Agent.update(cache, fn _ -> %{} end) end)

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Req.Test.json(conn, %{
        "totals" => %{"requests" => 1},
        "recent" => [%{"requested_model" => model}],
        "unused" => String.duplicate("x", 1_000_000)
      })
    end)

    cache.put("all", Http.usage(%{}))
    {:ok, page} = cache.get("all", {:page, %{}})
    retained = hd(page["recent"])["requested_model"]

    assert retained == model
    assert page["totals"]["requests"] == 1
    refute Map.has_key?(page, "unused")
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "404 → {:unavailable, :not_found}" do
    configure()

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:unavailable, :not_found} = Http.usage(%{})
  end

  test "a transient failure is returned without blocking for an internal retry" do
    configure()

    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, fn conn ->
      attempts = Process.get(:router_attempts, 0)
      Process.put(:router_attempts, attempts + 1)
      Plug.Conn.send_resp(conn, if(attempts == 0, do: 503, else: 200), "{}")
    end)

    assert {:unavailable, {:http, 503}} = Http.usage(%{})
    assert Process.get(:router_attempts) == 1
  end

  test "a successful status with a non-object body is unavailable" do
    configure()
    Req.Test.stub(SubzeroSwarmDashboard.HttpStub, &Req.Test.json(&1, ["unexpected"]))
    assert {:unavailable, :invalid_response} = Http.usage(%{})
  end
end
