defmodule SubzeroSwarmDashboard.RouterUsageCacheTest do
  use ExUnit.Case, async: false

  alias SubzeroSwarmDashboard.RouterUsageCache

  # The cache is supervised by the application (it must exist before any
  # LiveView mounts) — reset the running instance instead of starting a second.
  setup do
    Agent.update(RouterUsageCache, fn _ -> %{} end)
    :ok
  end

  test "stores and serves last-good results per range; missing range is nil" do
    assert RouterUsageCache.get("24h") == nil

    RouterUsageCache.put("24h", {:ok, %{"requests" => 5}})
    assert RouterUsageCache.get("24h") == {:ok, %{"requests" => 5}}
    assert RouterUsageCache.get("7d") == nil
  end

  test "errors are never cached (a down router must not be pre-painted later)" do
    RouterUsageCache.put("all", {:ok, %{"requests" => 1}})
    RouterUsageCache.put("all", {:unavailable, :not_configured})
    assert RouterUsageCache.get("all") == {:ok, %{"requests" => 1}}
  end
end
