defmodule SubzeroSwarmDashboardWeb.TopologyOverlayNoticeTest do
  # A rejected host overlay must be VISIBLE where its effect is missing — the
  # Topology page — not only in the pod's boot log. (The first wingston bake
  # shipped invalid JSON and the canvas just looked ungrouped.)
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    on_exit(fn -> Application.delete_env(:subzero_swarm_dashboard, :topology_overlay_error) end)
    :ok
  end

  test "no notice without an error", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/topology")
    refute html =~ "overlay rejected"
  end

  test "the rejection reason renders on the Topology page", %{conn: conn} do
    Application.put_env(
      :subzero_swarm_dashboard,
      :topology_overlay_error,
      ~s|unknown key "node_group" (known: ext_endpoints, node_aliases, node_groups, object_descriptions)|
    )

    {:ok, _view, html} = live(conn, "/topology")
    assert html =~ "host topology overlay rejected"
    assert html =~ "unknown key"
    assert html =~ "node_group"
  end
end
