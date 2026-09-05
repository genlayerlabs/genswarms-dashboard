defmodule SubzeroSwarmDashboard.TopologyOverlayTest do
  # The host topology overlay (README "Host overlay configuration") reaches
  # the app env from the ENVIRONMENT — DASHBOARD_TOPOLOGY_OVERLAY (inline
  # JSON) or DASHBOARD_TOPOLOGY_OVERLAY_FILE (path) — so a host that builds
  # the generic image (wingston bakes it via a build-arg; a k8s env var
  # overrides) never edits config files inside the package. Shape errors are
  # LOUD (the whole overlay is rejected with a reason, runtime.exs warns) —
  # a silently half-applied overlay would look like a canvas bug.
  use ExUnit.Case, async: false

  alias SubzeroSwarmDashboard.TopologyOverlay

  @overlay_vars ~w(DASHBOARD_TOPOLOGY_OVERLAY DASHBOARD_TOPOLOGY_OVERLAY_B64 DASHBOARD_TOPOLOGY_OVERLAY_FILE)

  defp with_env(vars, fun) do
    prev = Map.new(@overlay_vars, &{&1, System.get_env(&1)})
    Enum.each(@overlay_vars, &System.delete_env/1)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

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

  describe "from_env/1 base64 transport" do
    # docker/build-push-action parses `build-args` as CSV and strips quotes out
    # of a JSON value (observed: "payments","cron","tips" came through
    # unquoted). Base64 has no quotes or commas, so it survives any such
    # parser — the form to use with the standard action.
    @b64 Base.encode64(@full)

    test "DASHBOARD_TOPOLOGY_OVERLAY_B64 decodes to the same overlay as the inline JSON" do
      assert TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY_B64" => @b64}) ==
               TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY" => @full})
    end

    test "accepts unpadded and line-wrapped base64 (plain `base64` without -w0)" do
      unpadded = String.trim_trailing(@b64, "=")

      wrapped =
        @b64 |> String.graphemes() |> Enum.chunk_every(76) |> Enum.map_join("\n", &Enum.join/1)

      assert {:ok, [_ | _]} =
               TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY_B64" => unpadded})

      assert {:ok, [_ | _]} =
               TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY_B64" => wrapped <> "\n"})
    end

    test "rejects bytes that are not base64 — and base64 that is not JSON — with a reason" do
      assert {:error, "DASHBOARD_TOPOLOGY_OVERLAY_B64 is not base64" <> _} =
               TopologyOverlay.from_env(%{"DASHBOARD_TOPOLOGY_OVERLAY_B64" => "{not b64}"})

      assert {:error, "invalid JSON" <> _} =
               TopologyOverlay.from_env(%{
                 "DASHBOARD_TOPOLOGY_OVERLAY_B64" => Base.encode64("{nope")
               })
    end

    test "the base64 form takes precedence over inline and file" do
      assert {:ok, [ext_endpoints: ["web"]]} =
               TopologyOverlay.from_env(%{
                 "DASHBOARD_TOPOLOGY_OVERLAY_B64" => Base.encode64(~s({"ext_endpoints":["web"]})),
                 "DASHBOARD_TOPOLOGY_OVERLAY" => ~s({"ext_endpoints":["telegram"]})
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

    test "the base64 form reaches the app env too" do
      with_env(
        %{"DASHBOARD_TOPOLOGY_OVERLAY_B64" => Base.encode64(~s({"ext_endpoints":["web"]}))},
        fn ->
          cfg = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
          assert cfg[:subzero_swarm_dashboard][:ext_endpoints] == ["web"]
          refute Keyword.has_key?(cfg[:subzero_swarm_dashboard], :topology_overlay_error)
        end
      )
    end

    test "a rejected overlay leaves the compiled defaults and records the reason" do
      with_env(%{"DASHBOARD_TOPOLOGY_OVERLAY" => ~s({"node_group":{}})}, fn ->
        cfg =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            send(
              self(),
              {:cfg, Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)}
            )
          end)
          |> then(fn warned ->
            assert warned =~ "DASHBOARD_TOPOLOGY_OVERLAY"
            assert_received {:cfg, cfg}
            cfg
          end)

        app = cfg[:subzero_swarm_dashboard]
        refute Keyword.has_key?(app, :node_groups)
        assert app[:topology_overlay_error] =~ "unknown key"
      end)
    end
  end
end
