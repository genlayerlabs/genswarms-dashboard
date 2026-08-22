defmodule SubzeroSwarmDashboard.TopologyOverlayTest do
  # The host topology overlay (README "Host overlay configuration") reaches
  # the app env from the ENVIRONMENT — DASHBOARD_TOPOLOGY_OVERLAY (inline
  # JSON) or DASHBOARD_TOPOLOGY_OVERLAY_FILE (path) — so a host that builds
  # the generic image (wingston bakes it via a build-arg; a k8s env var
  # overrides) never edits config files inside the package. Shape errors are
  # LOUD (the whole overlay is rejected with a reason, runtime.exs warns) —
  # a silently half-applied overlay would look like a canvas bug.
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.TopologyOverlay

  @full ~s({"node_groups":{"ops":["metrics","cron"]},"object_descriptions":{"policy":"Decides.","agent":"One conversation."},"node_aliases":{"tg_ingress":"ingress"},"ext_endpoints":["telegram","web"]})

  describe "parse/1" do
    test "maps every documented key onto its app-env shape" do
      assert {:ok, overlay} = TopologyOverlay.parse(@full)

      assert overlay[:node_groups] == %{"ops" => ["metrics", "cron"]}
      # the "agent" description becomes the :agent atom key the layout reads
      assert overlay[:object_descriptions] == %{
               "policy" => "Decides.",
               agent: "One conversation."
             }

      assert overlay[:node_aliases] == %{"tg_ingress" => "ingress"}
      assert overlay[:ext_endpoints] == ["telegram", "web"]
    end

    test "only the keys present are set — absent keys keep their compiled defaults" do
      assert {:ok, overlay} = TopologyOverlay.parse(~s({"ext_endpoints":["telegram"]}))
      assert Keyword.keys(overlay) == [:ext_endpoints]
    end

    test "rejects invalid JSON, non-object roots and unknown keys with a reason" do
      assert {:error, "invalid JSON" <> _} = TopologyOverlay.parse("{nope")
      assert {:error, "overlay must be a JSON object" <> _} = TopologyOverlay.parse("[1]")
      assert {:error, msg} = TopologyOverlay.parse(~s({"node_group":{}}))
      assert msg =~ "unknown key"
      assert msg =~ "node_group"
    end

    test "rejects wrong shapes per key instead of half-applying" do
      assert {:error, msg} = TopologyOverlay.parse(~s({"node_groups":{"ops":"metrics"}}))
      assert msg =~ "node_groups"

      assert {:error, msg} = TopologyOverlay.parse(~s({"object_descriptions":{"policy":1}}))
      assert msg =~ "object_descriptions"

      assert {:error, msg} = TopologyOverlay.parse(~s({"node_aliases":["a"]}))
      assert msg =~ "node_aliases"

      assert {:error, msg} = TopologyOverlay.parse(~s({"ext_endpoints":"telegram"}))
      assert msg =~ "ext_endpoints"
    end
  end

  describe "from_env/1" do
    test "nothing set → empty overlay" do
      assert {:ok, []} = TopologyOverlay.from_env(%{})
      assert {:ok, []} = TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY" => "  "})
    end

    test "inline JSON wins; a file path is read when inline is blank" do
      path = Path.join(System.tmp_dir!(), "overlay-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"ext_endpoints":["web"]}))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, [ext_endpoints: ["web"]]} =
               TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY_FILE" => path})

      assert {:ok, [ext_endpoints: ["telegram"]]} =
               TopologyOverlay.from_env(%{
                 "DASHBOARD_TOPOLOGY_OVERLAY" => ~s({"ext_endpoints":["telegram"]}),
                 "DASHBOARD_TOPOLOGY_OVERLAY_FILE" => path
               })

      assert {:error, "cannot read" <> _} =
               TopologyOverlay.from_env(%{
                 "DASHBOARD_TOPOLOGY_OVERLAY_FILE" => path <> ".missing"
               })
    end
  end

  describe "config/runtime.exs wiring" do
    # Evaluate the real runtime config with the env var set — proves the hook
    # is wired, not just that the parser works.
    test "the overlay lands in the :subzero_swarm_dashboard app env" do
      prev = System.get_env("DASHBOARD_TOPOLOGY_OVERLAY")
      System.put_env("DASHBOARD_TOPOLOGY_OVERLAY", @full)

      on_exit(fn ->
        if prev,
          do: System.put_env("DASHBOARD_TOPOLOGY_OVERLAY", prev),
          else: System.delete_env("DASHBOARD_TOPOLOGY_OVERLAY")
      end)

      cfg = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
      app = cfg[:subzero_swarm_dashboard]

      assert app[:node_groups] == %{"ops" => ["metrics", "cron"]}
      assert app[:object_descriptions][:agent] == "One conversation."
      assert app[:ext_endpoints] == ["telegram", "web"]
    end
  end
end
