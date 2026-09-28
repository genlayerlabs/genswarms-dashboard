defmodule SubzeroSwarmDashboard.RouterUsageCacheTest do
  use ExUnit.Case, async: false
  import Mox

  alias SubzeroSwarmDashboard.RouterUsageCache
  setup :set_mox_global
  setup :verify_on_exit!

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

  test "overview projection excludes detail while paged detail keeps totals and later records" do
    rows = for i <- 1..60, do: %{"requested_model" => "model-#{i}"}
    stats = Map.new(1..60, &{"model-#{&1}", %{"requests" => &1}})

    RouterUsageCache.put(
      "all",
      {:ok,
       %{
         "totals" => %{
           "requests" => 20_000,
           "tokens_total" => 100_000,
           "errors" => 2,
           "extra" => rows
         },
         "recent" => rows,
         "by_served_model" => stats,
         "unused" => rows
       }}
    )

    assert {:ok, %{"totals" => %{"requests" => 20_000, "tokens_total" => 100_000, "errors" => 2}}} ==
             RouterUsageCache.get("all", :totals)

    assert {:ok, page} =
             RouterUsageCache.get("all", {:page, %{"recent" => 3, "by_served_model" => 3}})

    assert length(page["recent"]) == 10
    assert hd(page["recent"])["requested_model"] == "model-51"
    assert map_size(page["by_served_model"]) == 10
    assert page["pagination"]["recent"].total == 60
    assert page["totals"]["requests"] == 20_000
    refute Map.has_key?(page, "unused")
  end

  test "concurrent fetches share one request and fresh results while failures remain visible" do
    owner = self()

    expect(SubzeroSwarmDashboard.RouterClientMock, :usage, fn %{} ->
      send(owner, {:request, self()})

      receive do
        :finish -> {:ok, %{"totals" => %{"requests" => 8}}}
      end
    end)

    first = Task.async(fn -> RouterUsageCache.fetch("all", %{}, :totals) end)
    assert_receive {:request, requester}
    second = Task.async(fn -> RouterUsageCache.fetch("all", %{}, :totals) end)
    send(requester, :finish)
    assert Task.await(first) == {:ok, %{"totals" => %{"requests" => 8}}}
    assert Task.await(second) == {:ok, %{"totals" => %{"requests" => 8}}}
    assert RouterUsageCache.fetch("all", %{}, :totals) == {:ok, %{"totals" => %{"requests" => 8}}}

    Agent.update(RouterUsageCache, fn _ -> %{} end)
    RouterUsageCache.put("all", {:ok, %{"totals" => %{"requests" => 8}}})

    expect(SubzeroSwarmDashboard.RouterClientMock, :usage, fn %{} ->
      {:unavailable, {:http, 503}}
    end)

    assert RouterUsageCache.fetch("all", %{}, :totals) == {:unavailable, {:http, 503}}
    assert RouterUsageCache.fetch("all", %{}, :totals) == {:unavailable, {:http, 503}}
    assert RouterUsageCache.get("all", :totals) == {:ok, %{"totals" => %{"requests" => 8}}}
  end

  test "malformed router fields cannot crash the shared cache" do
    RouterUsageCache.put("all", {:ok, %{"totals" => []}})
    assert {:unavailable, :invalid_response} = RouterUsageCache.get("all", :totals)
    RouterUsageCache.put("24h", {:ok, %{"totals" => %{"requests" => 1}}})
    assert {:ok, %{"totals" => %{"requests" => 1}}} = RouterUsageCache.get("24h", :totals)
  end
end
