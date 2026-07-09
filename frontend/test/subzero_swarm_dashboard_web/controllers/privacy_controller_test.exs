defmodule SubzeroSwarmDashboardWeb.PrivacyControllerTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: true

  test "toggle flips the privacy session value and redirects to the referrer", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> put_req_header("referer", "http://www.example.com/sessions?view=active")
      |> post(~p"/privacy/toggle")

    assert redirected_to(conn) == "/sessions?view=active"
    assert get_session(conn, :privacy) == true

    conn =
      conn
      |> recycle()
      |> put_req_header("referer", "http://www.example.com/sessions?view=active")
      |> post(~p"/privacy/toggle")

    assert redirected_to(conn) == "/sessions?view=active"
    assert get_session(conn, :privacy) == false
  end

  test "toggle falls back to overview without a referrer", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> post(~p"/privacy/toggle")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :privacy) == true
  end
end
