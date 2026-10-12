defmodule SubzeroSwarmDashboardWeb.SessionsCopyTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp show_session(conn, user, label \\ nil) do
    {:ok, view, _} = live(conn, "/sessions")
    push_session(view, user, label)
    view
  end

  defp push_session(view, user, label \\ nil) do
    send(
      view.pid,
      {:snapshot,
       %{
         "sessions" => [
           %{
             "session_id" => "tg:903489662:0",
             "state" => "idle",
             "user" => user,
             "label" => label
           }
         ],
         "extensions" => %{}
       }}
    )

    render(view)
  end

  test "username and numeric ID have independent copy buttons", %{conn: conn} do
    view = show_session(conn, %{"handle" => "cognocracy"}, "@cognocracy")

    assert has_element?(
             view,
             "#sessions-table button[aria-label='Copy username'][data-copy-text='@cognocracy']"
           )

    assert has_element?(
             view,
             "#sessions-table button[aria-label='Copy ID'][data-copy-text='903489662']"
           )
  end

  test "a display name does not replace the username or ID copy targets", %{conn: conn} do
    view = show_session(conn, %{"name" => "Albert", "handle" => "cognocracy"})

    assert has_element?(view, "#sessions-table", "Albert")

    assert has_element?(
             view,
             "#sessions-table button[aria-label='Copy username'][data-copy-text='@cognocracy']"
           )

    assert has_element?(
             view,
             "#sessions-table button[aria-label='Copy ID'][data-copy-text='903489662']"
           )
  end

  test "a session without a username only offers the ID", %{conn: conn} do
    view = show_session(conn, nil)

    refute has_element?(view, "#sessions-table button[aria-label='Copy username']")

    assert has_element?(
             view,
             "#sessions-table button[aria-label='Copy ID'][data-copy-text='903489662']"
           )
  end

  test "privacy mode omits copy buttons and clipboard values", %{conn: conn} do
    view =
      conn |> init_test_session(%{privacy: true}) |> show_session(%{"handle" => "cognocracy"})

    refute has_element?(view, "#sessions-table [phx-hook='ClipboardCopy']")
    refute has_element?(view, "#sessions-table [data-copy-text]")
  end

  test "an ID button becomes a new hook when a snapshot replaces its line with a username", %{
    conn: conn
  } do
    view = show_session(conn, nil)

    [old_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[data-copy-text='903489662']")
      |> LazyHTML.attribute("id")

    push_session(view, %{"handle" => "cognocracy"})

    [username_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[data-copy-text='@cognocracy']")
      |> LazyHTML.attribute("id")

    # Ignored hooks only receive data-* patches: a new meaning needs a new ID
    # so the browser also receives the correct title and accessible label.
    refute old_id == username_id
    assert has_element?(view, "button[aria-label='Copy ID'][data-copy-text='903489662']")

    push_session(view, %{"name" => "Albert", "handle" => "cognocracy"})
    assert has_element?(view, "button[aria-label='Copy username'][data-copy-text='@cognocracy']")
    assert has_element?(view, "button[aria-label='Copy ID'][data-copy-text='903489662']")
  end

  test "equal display names and handles still give hooks unique IDs", %{conn: conn} do
    view = show_session(conn, %{"name" => "@cognocracy", "handle" => "cognocracy"})

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#sessions-table [phx-hook='ClipboardCopy']")
      |> LazyHTML.attribute("id")

    assert length(ids) >= 2
    assert length(ids) == length(Enum.uniq(ids))
  end
end
