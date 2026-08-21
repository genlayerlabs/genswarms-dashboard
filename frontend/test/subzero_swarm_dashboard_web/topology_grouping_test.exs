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

  describe "package groups" do
    setup do
      on_exit(fn ->
        Application.delete_env(:subzero_swarm_dashboard, :node_groups)
        Application.delete_env(:subzero_swarm_dashboard, :node_aliases)
      end)

      Application.put_env(:subzero_swarm_dashboard, :node_groups, %{
        "market" => ["market_bet", "market_resolution"],
        "ops" => ["metrics", "cron"],
        "ghost" => ["not_in_snapshot"]
      })

      {:ok,
       snap:
         snap(
           [
             {"object", "market_bet"},
             {"object", "market_resolution"},
             {"object", "metrics"},
             {"object", "cron"},
             {"object", "policy"}
           ],
           [
             {"market_bet", "policy"},
             {"market_resolution", "policy"},
             {"metrics", "policy"},
             {"market_bet", "market_resolution"}
           ]
         )}
    end

    test "collapsed groups replace members with ONE super-node; edges fold, meta describes", %{
      snap: snapshot
    } do
      layout = TopologyLive.pipeline_layout(snapshot)

      assert names(layout) == ["market", "ops", "policy"]
      # member↔member edges become self-loops and drop
      assert edges(layout) == [{"market", "policy"}, {"ops", "policy"}]

      by_name = Map.new(layout.nodes, &{&1.name, &1})
      assert by_name["market"].group == true
      assert by_name["policy"].group == false
      assert by_name["market"].desc =~ "2 objects"
      assert by_name["market"].desc =~ "market_bet"

      # a group with no member in the snapshot vanishes entirely
      assert Enum.map(layout.groups, & &1.name) == ["market", "ops"]
      assert %{count: 2, expanded: false} = hd(layout.groups)
    end

    test "host aliases flatten through collapsed groups", %{snap: snapshot} do
      Application.put_env(:subzero_swarm_dashboard, :node_aliases, %{"bet" => "market_bet"})

      layout = TopologyLive.pipeline_layout(snapshot)

      # "bet" → market_bet → its collapsed group; members alias to the group too
      assert layout.aliases["bet"] == "market"
      assert layout.aliases["market_bet"] == "market"
    end

    test "an expanded group fans members out inside a box; labels drop the group prefix", %{
      snap: snapshot
    } do
      layout = TopologyLive.pipeline_layout(snapshot, MapSet.new(["market"]))

      assert "market_bet" in names(layout)
      refute "market" in names(layout)

      by_name = Map.new(layout.nodes, &{&1.name, &1})
      assert by_name["market_bet"].label == "bet"

      assert [box] = layout.boxes
      assert box.name == "market"
      assert Enum.sort(box.members) == ["market_bet", "market_resolution"]

      # every member sits INSIDE the box rect
      for m <- box.members do
        assert {x, y} = {by_name[m].x, by_name[m].y}
        assert x >= box.x0 and x <= box.x1
        assert y >= box.y0 and y <= box.y1
      end

      # meta reports the expansion; the still-collapsed group keeps folding
      assert Enum.find(layout.groups, &(&1.name == "market")).expanded == true
      assert "ops" in names(layout)
    end

    test "expanded members never overlap each other", %{snap: snapshot} do
      layout = TopologyLive.pipeline_layout(snapshot, MapSet.new(["market", "ops"]))

      positions =
        for n <- layout.nodes, do: {n.name, {Float.round(n.x, 4), Float.round(n.y, 4)}}

      coords = Enum.map(positions, &elem(&1, 1))
      assert coords == Enum.uniq(coords)

      # two open boxes tile into disjoint lanes
      assert [a, b] = layout.boxes |> Enum.sort_by(& &1.x0)
      assert a.x1 <= b.x0 or a.y1 <= b.y0 or b.y1 <= a.y0
    end
  end
end

defmodule SubzeroSwarmDashboardWeb.TopologyGroupRoundTripTest do
  # The LiveView half of package groups: chips render under the canvas and a
  # click re-lays the canvas with that group's box open.
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
      on_exit(fn -> Application.delete_env(:subzero_swarm_dashboard, :node_groups) end)
      Application.put_env(:subzero_swarm_dashboard, :node_groups, %{"ops" => ["metrics", "cron"]})
      :ok
    end

    test "group chips render and a click re-lays the canvas with the box open", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/topology")

      send(
        view.pid,
        {:snapshot,
         %{
           "nodes" => [
             %{"type" => "object", "name" => "metrics"},
             %{"type" => "object", "name" => "cron"},
             %{"type" => "object", "name" => "policy"}
           ],
           "edges" => [%{"from" => "metrics", "to" => "policy"}]
         }}
      )

      html = render(view)
      assert html =~ "packages:"
      assert html =~ "▸ ops"

      view |> element(~s(button[phx-value-name="ops"])) |> render_click()

      assert_push_event(view, "pipeline:init", %{boxes: [box]})
      assert box.name == "ops"
      assert render(view) =~ "▾ ops"
    end
end
