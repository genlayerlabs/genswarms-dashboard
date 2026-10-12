defmodule SubzeroSwarmDashboardWeb.HealthControllerTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: true

  test "GET /healthz is unauthenticated and reports ok", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok", "service" => "subzero_swarm_dashboard"}
  end

  # Kubernetes and load balancer probes call the pod IP over plain HTTP, so the
  # localhost host exemption does not cover them.
  test "prod force_ssl serves plain-HTTP /healthz and still redirects other paths" do
    ssl_opts =
      "config/prod.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:subzero_swarm_dashboard, SubzeroSwarmDashboardWeb.Endpoint, :force_ssl])
      |> Keyword.put(:log, false)
      |> Plug.SSL.init()

    probe = fn path -> Plug.SSL.call(%{build_conn(:get, path) | host: "10.0.0.7"}, ssl_opts) end

    refute probe.("/healthz").halted
    assert probe.("/").status == 301
  end
end
