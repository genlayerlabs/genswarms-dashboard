defmodule SubzeroSwarmDashboardWeb.DashboardAuthTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  setup do
    previous = Map.new(~w(DASHBOARD_USER DASHBOARD_PASS), &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> put_env(key, value) end) end)
    :ok
  end

  test "incomplete or whitespace-only Basic Auth fails closed" do
    for {user, pass} <- [
          {"operator", nil},
          {nil, "secret"},
          {"operator", ""},
          {"", "secret"},
          {" ", "\t"},
          {"operator", "  "}
        ] do
      credentials(user, pass)

      conn =
        build_conn()
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth(user || "", pass || "")
        )
        |> get("/")

      assert response(conn, 503) == "Dashboard authentication is not configured correctly"
      assert conn.halted
    end
  end

  test "configured Basic Auth rejects missing or wrong credentials and accepts the right pair" do
    credentials("operator", "test-password")
    assert build_conn() |> get("/") |> response(401)

    assert build_conn()
           |> put_req_header(
             "authorization",
             Plug.BasicAuth.encode_basic_auth("operator", "wrong")
           )
           |> get("/")
           |> response(401)

    assert build_conn()
           |> put_req_header(
             "authorization",
             Plug.BasicAuth.encode_basic_auth("operator", "test-password")
           )
           |> get("/")
           |> html_response(200)
  end

  test "both variables absent preserves authentication delegated to the ingress" do
    credentials(nil, nil)
    assert build_conn() |> get("/") |> html_response(200)
  end

  test "both variables empty preserves Compose authentication delegated to the ingress" do
    credentials("", "")
    assert build_conn() |> get("/") |> html_response(200)
  end

  test "health remains available when Basic Auth is misconfigured" do
    credentials("operator", "")

    assert build_conn() |> get("/healthz") |> json_response(200) ==
             %{"status" => "ok", "service" => "subzero_swarm_dashboard"}
  end

  defp credentials(user, pass) do
    put_env("DASHBOARD_USER", user)
    put_env("DASHBOARD_PASS", pass)
  end

  defp put_env(key, nil), do: System.delete_env(key)
  defp put_env(key, value), do: System.put_env(key, value)
end
