defmodule SubzeroSwarmDashboardWeb.TopologyGroupingTest do
  # Canvas-side topology reduction (ported from micromarkets' X Layer
  # dashboard upgrade): sharded workers fold into their router, and
  # host-configured package groups collapse many objects into super-nodes.
  # These pin the pure layout half — pipeline_layout/2 — which the hook
  # consumes verbatim.
  use ExUnit.Case, async: false

  alias SubzeroSwarmDashboardWeb.TopologyLive

  defp snap(nodes, edges) do
    %{
      "nodes" => Enum.map(nodes, fn {t, n} -> %{"type" => t, "name" => n} end),
      "edges" => Enum.map(edges, fn {f, t} -> %{"from" => f, "to" => t} end)
    }
  end

  defp names(layout), do: layout.nodes |> Enum.map(& &1.name) |> Enum.sort()
  defp edges(layout), do: layout.edges |> Enum.map(&{&1.from, &1.to}) |> Enum.sort()

  test "shard workers fold into their router; edges follow, self-loops drop" do
    layout =
      TopologyLive.pipeline_layout(
        snap(
          [
            {"object", "market_bet"},
            {"object", "market_bet_shard_1"},
            {"object", "market_bet_shard_2"},
            {"object", "policy"}
          ],
          [
            {"market_bet", "market_bet_shard_1"},
            {"market_bet_shard_1", "policy"},
            {"market_bet_shard_2", "policy"}
          ]
        )
      )

    assert names(layout) == ["market_bet", "policy"]
    # both shard->policy edges fold onto ONE router->policy edge; the
    # router->shard edge becomes a self-loop and is dropped
    assert edges(layout) == [{"market_bet", "policy"}]
  end

  test "shards stay as plain nodes when their router is absent from the snapshot" do
    layout =
      TopologyLive.pipeline_layout(
        snap(
          [{"object", "orphan_shard_1"}, {"object", "policy"}],
          [{"orphan_shard_1", "policy"}]
        )
      )

    assert names(layout) == ["orphan_shard_1", "policy"]
    assert edges(layout) == [{"orphan_shard_1", "policy"}]
  end
end
