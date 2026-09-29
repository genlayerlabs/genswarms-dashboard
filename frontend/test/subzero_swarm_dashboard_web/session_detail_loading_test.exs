defmodule SubzeroSwarmDashboardWeb.SessionDetailLoadingTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.SwarmClientMock

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:subzero_swarm_dashboard, :reveal_transcripts_default)
    Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, true)

    on_exit(fn ->
      Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, previous)
    end)

    stub(SwarmClientMock, :session_history, fn _, _ -> transcript("Saved message") end)
    stub(SwarmClientMock, :session_logs, fn _, _ -> {:ok, %{"logs" => []}} end)
    stub(SwarmClientMock, :session_skills, fn _, _ -> {:ok, %{"skills" => []}} end)
    :ok
  end

  defp transcript(text),
    do: {:ok, %{"source" => "store", "turns" => [%{"role" => "user", "content" => text}]}}

  test "a completion queued before hide cannot start a pending sensitive refresh" do
    for key <- [:transcript, :activity] do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          swarm: "synthetic",
          session_id: "synthetic:1:0",
          reveal_transcripts: false,
          detail_loading: MapSet.new([key]),
          detail_pending: MapSet.new([key]),
          detail_errors: MapSet.new()
        }
      }

      {:noreply, socket} =
        SubzeroSwarmDashboardWeb.SessionDetailLive.handle_async(
          key,
          {:ok, transcript("Private")},
          socket
        )

      assert socket.assigns[key] == :hidden
      assert Enum.empty?(socket.assigns.detail_loading)
      assert Enum.empty?(socket.assigns.detail_pending)
    end
  end

  test "a slow log request cannot block the conversation or the hide control", %{conn: conn} do
    parent = self()

    stub(SwarmClientMock, :session_history, fn _, _ ->
      send(parent, {:history_waiting, self()})

      receive do
        :finish -> transcript("Saved message")
      end
    end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      send(parent, {:logs_waiting, self()})

      receive do
        :finish -> {:ok, %{"logs" => []}}
      after
        2_000 -> {:error, :timeout}
      end
    end)

    {:ok, view, _} = live(conn, "/sessions/synthetic:1:0")
    assert_receive {:history_waiting, history}, 500
    assert_receive {:logs_waiting, worker}, 500
    ref = Process.monitor(history)
    send(history, :finish)
    assert_receive {:DOWN, ^ref, :process, ^history, :normal}, 500

    start_supervised!(
      {Task,
       fn ->
         send(
           parent,
           {:conversation_visible, has_element?(view, "#session-conversation", "Saved message")}
         )

         render_click(view, "transcripts_hide", %{})
         send(parent, {:hidden, has_element?(view, "#session-conversation")})
       end}
    )

    try do
      assert_receive {:conversation_visible, true}, 500
      assert_receive {:hidden, false}, 500
    after
      send(worker, :finish)
    end

    render_async(view)
    refute has_element?(view, "#session-conversation")
  end

  test "hiding cancels an in-flight transcript and a new reveal can load safely", %{conn: conn} do
    parent = self()

    expect(SwarmClientMock, :session_history, fn _, _ ->
      send(parent, {:history_waiting, self()})

      receive do
        :finish -> transcript("Old private message")
      end
    end)

    {:ok, view, _} = live(conn, "/sessions/synthetic:1:0")
    assert_receive {:history_waiting, worker}, 500
    ref = Process.monitor(worker)
    render_click(view, "transcripts_hide", %{})
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 500
    render_async(view)
    refute has_element?(view, "#session-conversation")

    expect(SwarmClientMock, :session_history, fn _, _ -> {:error, :timeout} end)
    render_click(view, "transcripts_reveal", %{})
    render_async(view)
    assert has_element?(view, "#session-transcript-error")
    refute has_element?(view, "#session-chat-panel button[phx-click=transcripts_reveal]")

    expect(SwarmClientMock, :session_history, fn _, _ -> transcript("New private message") end)
    view |> element("#session-refresh") |> render_click()
    render_async(view)
    assert has_element?(view, "#session-conversation", "New private message")
    refute has_element?(view, "#session-conversation", "Old private message")
  end

  @tag capture_log: true
  test "first-load errors leave the page usable and recover on refresh", %{conn: conn} do
    stub(SwarmClientMock, :session_history, fn _, _ -> exit(:unavailable) end)
    {:ok, view, _} = live(conn, "/sessions/synthetic:1:0")
    render_async(view)
    assert has_element?(view, "#session-transcript-error")
    refute has_element?(view, "#session-conversation")

    stub(SwarmClientMock, :session_history, fn _, _ -> transcript("Recovered message") end)
    view |> element("#session-refresh") |> render_click()
    render_async(view)
    assert has_element?(view, "#session-conversation", "Recovered message")
    refute has_element?(view, "#session-transcript-error")
  end

  test "failed refresh keeps saved messages visible and can be retried", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions/synthetic:1:0")
    render_async(view)
    assert has_element?(view, "#session-conversation", "Saved message")

    stub(SwarmClientMock, :session_history, fn _, _ -> {:error, :timeout} end)
    view |> element("#session-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#session-conversation", "Saved message")
    assert has_element?(view, "#session-transcript-error")

    stub(SwarmClientMock, :session_history, fn _, _ -> transcript("Recovered message") end)
    view |> element("#session-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#session-conversation", "Recovered message")
    refute has_element?(view, "#session-transcript-error")
  end

  test "snapshot changes coalesce while a history request is in flight", %{conn: conn} do
    parent = self()

    expect(SwarmClientMock, :session_history, fn _, _ ->
      send(parent, {:history_waiting, self()})

      receive do
        :finish -> transcript("Initial message")
      after
        2_000 -> {:error, :timeout}
      end
    end)

    expect(SwarmClientMock, :session_history, fn _, _ -> transcript("Newest message") end)

    {:ok, view, _} = live(conn, "/sessions/synthetic:1:0")
    assert_receive {:history_waiting, worker}, 500

    for activity <- [1, 2, 3] do
      send(
        view.pid,
        {:snapshot,
         %{"sessions" => [%{"session_id" => "synthetic:1:0", "last_activity" => activity}]}}
      )
    end

    # A mailbox barrier ensures every change arrived while the first request was pending.
    _ = :sys.get_state(view.pid, 500)
    send(worker, :finish)
    render_async(view)
    render_async(view)
    assert has_element?(view, "#session-conversation", "Newest message")
  end
end
