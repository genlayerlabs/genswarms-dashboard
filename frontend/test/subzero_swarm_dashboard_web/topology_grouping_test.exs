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

  describe "host vocabulary aliases + external endpoints" do
    setup do
      on_exit(fn ->
        Application.delete_env(:subzero_swarm_dashboard, :node_aliases)
        Application.delete_env(:subzero_swarm_dashboard, :ext_endpoints)
      end)
    end

    test "host node aliases ride the layout payload for the hook's packet resolution" do
      Application.put_env(:subzero_swarm_dashboard, :node_aliases, %{"ingress" => "tg_ingress"})

      layout =
        TopologyLive.pipeline_layout(snap([{"object", "tg_ingress"}], []))

      assert layout.aliases == %{"ingress" => "tg_ingress"}
    end

    test "without config the alias map is empty and no ext nodes render" do
      layout = TopologyLive.pipeline_layout(snap([{"object", "policy"}], []))

      assert layout.aliases == %{}
      refute Enum.any?(layout.nodes, &(&1.kind == "ext"))
    end

    test "configured external endpoints render as ext circles on the right edge" do
      Application.put_env(:subzero_swarm_dashboard, :ext_endpoints, ["telegram", "web"])

      layout = TopologyLive.pipeline_layout(snap([{"object", "policy"}], []))

      ext = Enum.filter(layout.nodes, &(&1.kind == "ext"))
      assert Enum.map(ext, & &1.name) |> Enum.sort() == ["telegram", "web"]
      assert Enum.all?(ext, &(&1.x > 0.9))
      # stacked, not overlapping
      assert ext |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 2
    end
  end

  describe "hover description cards" do
    setup do
      on_exit(fn ->
        Application.delete_env(:subzero_swarm_dashboard, :object_descriptions)
        Application.delete_env(:subzero_swarm_dashboard, :ext_endpoints)
      end)
    end

    test "host object descriptions attach per node; :agent covers dynamic agent chips" do
      Application.put_env(:subzero_swarm_dashboard, :object_descriptions, %{
        "policy" => "Decides who may do what.",
        "telegram" => "The Telegram Bot API.",
        agent: "One conversation's agent."
      })

      Application.put_env(:subzero_swarm_dashboard, :ext_endpoints, ["telegram"])

      layout = TopologyLive.pipeline_layout(snap([{"object", "policy"}, {"object", "sender"}], []))

      by_name = Map.new(layout.nodes, &{&1.name, &1})
      assert by_name["policy"].desc == "Decides who may do what."
      assert by_name["sender"].desc == nil
      assert by_name["telegram"].desc == "The Telegram Bot API."
      assert layout.agent_desc == "One conversation's agent."
    end

    test "without config, descs are nil and agent_desc absent" do
      layout = TopologyLive.pipeline_layout(snap([{"object", "policy"}], []))

      assert hd(layout.nodes).desc == nil
      assert layout.agent_desc == nil
    end
  end
end
