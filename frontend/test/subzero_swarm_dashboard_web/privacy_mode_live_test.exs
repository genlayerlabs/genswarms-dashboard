defmodule SubzeroSwarmDashboardWeb.PrivacyModeLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.RouterClientMock

  setup :set_mox_global

  setup do
    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    :ok
  end

  test "overview receives privacy from the session and renders the active chrome", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-privacy="on")
    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(id="privacy-badge")
    assert html =~ ~r/<span id="privacy-badge"[^>]*>\s*privacy\s*<\/span>/
    assert html =~ "hero-eye-slash"
  end

  test "privacy badge is absent when privacy is off", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-privacy="off")
    assert html =~ ~s(aria-pressed="false")
    assert html =~ "hero-eye"
    refute html =~ ~s(id="privacy-badge")
  end
end
