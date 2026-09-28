defmodule SubzeroSwarmDashboardWeb.UsageScaleTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{RouterClientMock, RouterUsageCache}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Agent.update(RouterUsageCache, fn _ -> %{} end)
    :ok
  end

  test "a slow usage request leaves the view responsive and an old range cannot overwrite the new one",
       %{conn: conn} do
    owner = self()

    stub(RouterClientMock, :usage, fn opts ->
      if Map.has_key?(opts, :since) do
        {:ok, %{"totals" => %{"requests" => 99}}}
      else
        send(owner, {:waiting, self()})

        receive do
          :finish -> {:ok, %{"totals" => %{"requests" => 1}}}
        after
          3_000 -> {:unavailable, :timeout}
        end
      end
    end)

    {:ok, view, _} = live(conn, "/usage")
    assert_receive {:waiting, requester}

    change =
      Task.async(fn -> view |> element("button[phx-value-window='1h']") |> render_click() end)

    response = Task.yield(change, 500)
    send(requester, :finish)
    assert {:ok, _} = response
    render_async(view)

    assert :sys.get_state(view.pid).socket.assigns.usage
           |> elem(1)
           |> get_in(["totals", "requests"]) == 99

    assert :sys.get_state(view.pid).socket.assigns.range == "1h"
  end

  test "usage tables retain bounded pages and expose later rows without another router request",
       %{conn: conn} do
    payload = payload()
    expect(RouterClientMock, :usage, fn %{} -> {:ok, payload} end)
    {:ok, view, _} = live(conn, "/usage")
    render_async(view)

    assert has_element?(view, "#usage-recent tr", "request-1")
    refute has_element?(view, "#usage-recent tr", "request-60")

    assert length(
             :sys.get_state(view.pid).socket.assigns.usage
             |> elem(1)
             |> Map.fetch!("recent")
           ) == 25

    view |> element("#usage-recent-page-next") |> render_click()
    view |> element("#usage-recent-page-next") |> render_click()
    assert has_element?(view, "#usage-recent tr", "request-60")
    assert has_element?(view, "#usage-recent-page", "60")

    view
    |> element("#usage-by_served_model-page form")
    |> render_submit(%{"page" => "3", "sec" => "by_served_model"})

    assert has_element?(view, "#usage-by_served_model", "model-1")
    refute has_element?(view, "#usage-by_served_model", "model-60")

    assert :sys.get_state(view.pid).socket.assigns.usage
           |> elem(1)
           |> get_in(["totals", "requests"]) == 20_000
  end

  test "Overview retains only summary totals", %{conn: conn} do
    expect(RouterClientMock, :usage, fn %{} -> {:ok, payload()} end)
    {:ok, view, _} = live(conn, "/")
    render_async(view)

    assert :sys.get_state(view.pid).socket.assigns.usage ==
             {:ok,
              %{"totals" => %{"requests" => 20_000, "tokens_total" => 80_000, "errors" => 2}}}
  end

  test "a queued pagination event cannot replace a router failure with last-good data", %{
    conn: conn
  } do
    RouterUsageCache.put("all", {:ok, payload()})
    expect(RouterClientMock, :usage, fn %{} -> {:unavailable, {:http, 503}} end)
    {:ok, view, _} = live(conn, "/usage")
    render_async(view)
    assert has_element?(view, "#usage-unavailable", "Router detail unavailable")

    render_click(view, "usage_page", %{"sec" => "recent", "page" => "2"})
    assert has_element?(view, "#usage-unavailable", "Router detail unavailable")
    refute has_element?(view, "#usage-recent")
  end

  defp payload do
    %{
      "totals" => %{"requests" => 20_000, "tokens_total" => 80_000, "errors" => 2},
      "recent" => for(i <- 1..60, do: %{"requested_model" => "request-#{i}"}),
      "by_served_model" => Map.new(1..60, &{"model-#{&1}", %{"requests" => &1}})
    }
  end
end
