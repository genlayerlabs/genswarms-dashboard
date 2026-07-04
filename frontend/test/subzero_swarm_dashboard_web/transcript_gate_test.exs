defmodule SubzeroSwarmDashboardWeb.TranscriptGateTest do
  @moduledoc """
  Sensitive-content gate: with the production default (hidden), user
  conversations are NOT FETCHED — not merely not rendered — until the
  per-browser reveal. The reveal/hide events flip the gate live.
  """
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, false)
    on_exit(fn -> Application.put_env(:subzero_swarm_dashboard, :reveal_transcripts_default, true) end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :dashboard, fn _swarm ->
      {:ok,
       %{
         "swarm" => "wingston",
         "sessions" => [
           %{"session_id" => "tg:1:0", "state" => "active", "agent" => "wingston_agent_0"}
         ]
       }}
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_skills, fn _s, _id ->
      {:ok, %{"source" => "slot", "skills" => []}}
    end)

    :ok
  end

  defp secret_transcript do
    {:ok, %{"source" => "db", "turns" => [%{"role" => "user", "content" => "SECRET-USER-TEXT"}]}}
  end

  test "hidden by default: session page never fetches the conversation", %{conn: conn} do
    # 0 expected calls — a fetch while gated is the failure this guards against
    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_history, 0, fn _s, _id ->
      secret_transcript()
    end)

    expect(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, 0, fn _s, _id ->
      {:ok, %{"source" => "agent_server", "logs" => []}}
    end)

    {:ok, view, _html} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "User conversation hidden"
    assert html =~ "Reveal conversations"
    refute html =~ "SECRET-USER-TEXT"
  end

  test "the reveal event fetches and renders; hide re-gates", %{conn: conn} do
    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_history, fn _s, _id ->
      secret_transcript()
    end)

    stub(SubzeroSwarmDashboard.SwarmClientMock, :session_logs, fn _s, _id ->
      {:ok, %{"source" => "agent_server", "logs" => []}}
    end)

    {:ok, view, _html} = live(conn, "/sessions/tg:1:0")
    html = render(view)
    refute html =~ "SECRET-USER-TEXT"
    # both gated panels offer the reveal (Conversation + Agent activity)
    assert html =~ ~s(phx-click="transcripts_reveal")

    render_click(view, "transcripts_reveal", %{})
    assert render(view) =~ "SECRET-USER-TEXT"

    render_click(view, "transcripts_hide", %{})
    html = render(view)
    refute html =~ "SECRET-USER-TEXT"
    assert html =~ "User conversation hidden"
  end
end
