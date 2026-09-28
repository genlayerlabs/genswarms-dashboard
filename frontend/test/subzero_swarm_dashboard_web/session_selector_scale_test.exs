defmodule SubzeroSwarmDashboardWeb.SessionSelectorScaleTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{SwarmClientMock, SwarmFeed}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    snapshot = %{
      "swarm" => "wingston",
      "summary" => %{"agents" => 0},
      "extensions" => %{},
      "sessions" =>
        for i <- 1..20_000 do
          %{
            "session_id" => "tg:#{i}:0",
            "state" => "idle",
            "agent" => nil,
            "user" => %{"handle" => "person-#{i}"}
          }
        end
    }

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, snapshot} end)
    stub(SwarmClientMock, :session_logs, fn _, _ -> {:ok, %{"logs" => []}} end)
    SwarmFeed.subscribe()
    start_supervised!(SwarmFeed)
    assert_receive {:snapshot_ready, _}, 2_000
    :ok
  end

  for page <- ["logs", "events"], privacy? <- [false, true] do
    @page page
    @privacy privacy?
    test "#{page} searches the full shared roster and preserves selection (privacy #{privacy?})",
         %{conn: conn} do
      {:ok, view, _} = live(init_test_session(conn, %{privacy: @privacy}), "/#{@page}")
      assert has_element?(view, "#session-search-status", "20,000")
      assert has_element?(view, "#session-search-status", "50")

      view |> element("#session-search-form") |> render_change(%{"q" => "person-20000"})
      assert has_element?(view, "#session-search-status", "1")
      select = if @page == "logs", do: "#logs-session-select", else: "#story-user-select"

      [target] =
        view
        |> element(select <> " option:not([value=''])")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.filter("option")
        |> LazyHTML.attribute("value")

      if @privacy,
        do: assert(String.starts_with?(target, "inspect:")),
        else: assert(target == "tg:20000:0")

      if @page == "logs" do
        view |> element("#logs-session-form") |> render_change(%{"session_id" => target})
      else
        view
        |> element("#story-filter-form")
        |> render_change(%{"_target" => ["user"], "user" => target})
      end

      view |> element("#session-search-form") |> render_change(%{"q" => "person-1"})
      assert has_element?(view, select <> " option[value='#{target}'][selected]")
      state = :sys.get_state(view.pid).socket.assigns
      assert if(@page == "logs", do: state.selected, else: state.cid) == "tg:20000:0"
      assert length(state.snapshot["sessions"]) <= 51
      refute Map.has_key?(state, :snapshot_source)

      if @privacy do
        html = render(view)
        refute html =~ "tg:20000:0"
        refute html =~ "tg%3A20000%3A0"
        refute html =~ "person-20000"
        refute html =~ "value=\"person-1\""
      end
    end
  end

  test "an Events deep link includes the selected user beyond the initial preview", %{conn: conn} do
    {:ok, view, _} = live(conn, "/events?cid=tg:20000:0")

    assert has_element?(
             view,
             "#story-user-select option[value='tg:20000:0'][selected]",
             "person-20000"
           )
  end

  test "an unavailable roster labels known matches without reporting a complete population", %{
    conn: conn
  } do
    for path <- ["/logs", "/events"] do
      {:ok, view, _} = live(conn, path)

      send(
        view.pid,
        {:snapshot,
         %{
           "sessions_available" => false,
           "sessions" => [%{"session_id" => "tg:9:0", "user" => %{"handle" => "known"}}]
         }}
      )

      render(view)
      assert has_element?(view, "#session-search-status", "Session source unavailable")
      assert has_element?(view, "#session-search-status", "1 known matches")
      refute has_element?(view, "#session-search-status", "loaded of")

      send(view.pid, {:snapshot, %{"sessions_available" => false, "sessions" => []}})
      render(view)
      assert has_element?(view, "#session-search-status", "total unknown")
      refute has_element?(view, "#session-search-status", "0 loaded of 0")
    end
  end
end
