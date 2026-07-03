defmodule SubzeroSwarmDashboard.RouterUsageCacheTest do
  use ExUnit.Case, async: false

  alias SubzeroSwarmDashboard.RouterUsageCache

  test "stores and serves last-good results per range" do
    start_supervised!(RouterUsageCache)
    assert RouterUsageCache.get("24h") == nil

    RouterUsageCache.put("24h", {:ok, %{"requests" => 5}})
    assert RouterUsageCache.get("24h") == {:ok, %{"requests" => 5}}
    assert RouterUsageCache.get("7d") == nil
  end

  test "errors are never cached (a down router must not be pre-painted later)" do
    start_supervised!(RouterUsageCache)
    RouterUsageCache.put("all", {:ok, %{"requests" => 1}})
    RouterUsageCache.put("all", {:unavailable, :not_configured})
    assert RouterUsageCache.get("all") == {:ok, %{"requests" => 1}}
  end

  test "nil-safe when not running" do
    assert RouterUsageCache.get("all") == nil
    assert RouterUsageCache.put("all", {:ok, %{}}) == :ok
  end
end
