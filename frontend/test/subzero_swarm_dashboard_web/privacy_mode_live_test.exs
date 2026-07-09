defmodule SubzeroSwarmDashboardWeb.PrivacyModeLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{RouterClientMock, RouterUsageCache, SwarmClientMock}

  setup :set_mox_global

  @canary_handle "canary_h4ndle"
  @canary_name "Canary Q. Name"
  @canary_cid "tg:987654321:0"
  @canary_cid_encoded Base.url_encode64(@canary_cid, padding: false)
  @canary_chat_id "987654321"
  @canary_text "CANARY-TEXT"

  @canary_snap %{
    "swarm" => "wingston",
    "dashboard_title" => "Wingston",
    "status" => "running",
    "generated_at" => "2026-07-08T12:00:00Z",
    "summary" => %{
      "agents" => 1,
      "objects" => 2,
      "pool" => %{"size" => 4, "leased" => 1, "idle" => 3}
    },
    "nodes" => [
      %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
      %{
        "name" => "wingston_agent_0",
        "type" => "agent",
        "state" => "active",
        "session_id" => @canary_cid
      }
    ],
    "edges" => [%{"from" => "ingress", "to" => "wingston_agent_0"}],
    "sessions" => [
      %{
        "session_id" => @canary_cid,
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-07-08T12:00:00Z",
        "transport_ref" => %{"chat_id" => @canary_chat_id, "thread_id" => "0"},
        "metadata" => %{"chat_type" => "dm"},
        "user" => %{"handle" => @canary_handle, "name" => @canary_name}
      }
    ],
    "extensions" => %{
      "consumers" => %{
        "count" => 1,
        "items" => [%{"session_id" => @canary_cid, "mode" => "scout", "opt_out" => false}]
      }
    },
    "warnings" => []
  }

  setup do
    parent = self()

    try do
      Agent.update(RouterUsageCache, fn _ -> %{} end)
    catch
      :exit, _ -> :ok
    end

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @canary_snap} end)
    stub(SwarmClientMock, :events, fn _, _ -> {:ok, [canary_event()]} end)
    stub(SwarmClientMock, :config, fn _ -> {:ok, %{"objects" => []}} end)

    stub(SwarmClientMock, :session_history, fn _, @canary_cid ->
      send(parent, {:history_loaded, @canary_cid})

      {:ok,
       %{
         "session_id" => @canary_cid,
         "source" => "store",
         "turns" => [
           %{"role" => "user", "content" => @canary_text, "at" => 1_782_000_000},
           %{"role" => "assistant", "content" => "reply #{@canary_text}", "at" => 1_782_000_060}
         ]
       }}
    end)

    stub(SwarmClientMock, :session_logs, fn _, @canary_cid ->
      send(parent, {:logs_loaded, @canary_cid})

      {:ok,
       %{
         "source" => "agent_server",
         "logs" => [
           %{"timestamp" => "2026-07-08T12:00:00Z", "role" => "user", "content" => @canary_text}
         ]
       }}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
    end)

    :ok
  end

  defp push_canary_snap(view, snap \\ @canary_snap) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    render(view)
  end

  defp push_canary_story(view) do
    push_story(view, canary_story())
  end

  defp push_story(view, story) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:story, story})
    render(view)
  end

  defp canary_story(overrides \\ %{}) do
    Map.merge(
      %{
        feed_status: :ok,
        feed_age_s: 0,
        baseline_at: ~U[2026-07-08 12:00:00Z],
        in_flight: [
          %{
            cid: @canary_cid,
            user: @canary_handle,
            agent: "wingston_agent_0",
            count: 1,
            opened_at: 1.0,
            elapsed_s: 3.5,
            stalled: false,
            activity: "thinking"
          }
        ],
        agents: [],
        kpis: %{},
        issues: [],
        story: []
      },
      overrides
    )
  end

  defp canary_story_row(attrs \\ %{}) do
    Map.merge(
      %{
        seq: 987,
        ts: 1_782_000_000.0,
        kind: "request_open",
        cid: @canary_cid,
        agent: "wingston_agent_0",
        issue: false,
        text: "#{@canary_text} from #{@canary_cid}"
      },
      attrs
    )
  end

  defp canary_event do
    %{
      "timestamp" => "2026-07-08T12:00:00Z",
      "level" => "info",
      "category" => "agent",
      "agent" => "wingston_agent_0",
      "message" => @canary_text,
      "metadata" => %{
        "cid" => @canary_cid,
        "chat_id" => @canary_chat_id,
        "user" => %{"handle" => @canary_handle, "name" => @canary_name}
      }
    }
  end

  defp canary_usage do
    %{
      "schema_version" => 2,
      "detail_level" => "full",
      "totals" => %{"requests" => 1, "tokens_total" => 42, "errors" => 0},
      "by_route" => %{@canary_cid => %{"requests" => 1, "tokens_total" => 42}},
      "by_provider" => %{"openai" => %{"requests" => 1, "tokens_total" => 42}},
      "by_served_model" => %{"gpt-test" => %{"requests" => 1, "tokens_total" => 42}},
      "by_model_family" => %{"test" => %{"requests" => 1, "tokens_total" => 42}},
      "consumer_settings" => %{
        "status" => "active",
        "allowed_routes" => [@canary_cid],
        "effective_per_min" => 60
      },
      "key" => %{"sha256_prefix" => "ab12cd34", "status" => "active"},
      "health_summary" => %{"state" => "healthy", "success_rate" => 1.0, "status_counts" => %{}},
      "route_health" => [%{"route" => @canary_cid, "state" => "healthy"}],
      "recent" => [
        %{
          "ts" => System.os_time(:second),
          "status" => 500,
          "served_model_id" => "gpt-test",
          "path" => "/v1/chat/#{@canary_chat_id}",
          "latency_ms" => 12,
          "tokens_total" => 42,
          "error_message" => @canary_text
        }
      ],
      "security" => %{"sanitized" => true}
    }
  end

  defp canary_config do
    %{
      "objects" => [
        %{
          "name" => "sender",
          "handler" => "Sender",
          "has_schema" => true,
          "config" => [
            %{
              "key" => "alert_cids",
              "value" => [@canary_cid],
              "description" => "where alert cids are delivered",
              "mutable" => true,
              "secret" => false
            },
            %{
              "key" => "owner_handle",
              "value" => @canary_handle,
              "description" => "operator handle",
              "mutable" => false,
              "secret" => false
            },
            %{
              "key" => "display_name",
              "value" => @canary_name,
              "description" => "operator name",
              "mutable" => false,
              "secret" => false
            }
          ]
        }
      ]
    }
  end

  defp canary_extension_snap do
    put_in(@canary_snap, ["extensions", "dashboard_pages"], [
      %{
        "id" => "canary-report",
        "label" => @canary_handle,
        "meta" => @canary_cid,
        "sections" => [
          %{
            "type" => "metrics",
            "title" => "Summary",
            "items" => [
              %{"label" => "owner", "value" => @canary_name, "sub" => @canary_cid},
              %{"label" => "count", "value" => 7}
            ]
          },
          %{
            "type" => "table",
            "title" => "Consumers",
            "columns" => [
              %{"key" => "handle", "label" => "handle"},
              %{"key" => "name", "label" => "name"},
              %{"key" => "cid", "label" => "cid"},
              %{"key" => "message", "label" => "message"}
            ],
            "rows" => [
              %{
                "handle" => @canary_handle,
                "name" => @canary_name,
                "cid" => @canary_cid,
                "message" => @canary_text
              }
            ]
          }
        ]
      }
    ])
  end

  defp canary_usage_snap do
    @canary_snap
    |> put_in(["extensions", "metrics_today"], %{"replies" => 1})
    |> put_in(["extensions", "usage_tiles"], [
      %{"label" => @canary_handle, "value" => @canary_name, "sub" => @canary_cid}
    ])
  end

  defp canary_warning_snap do
    Map.put(@canary_snap, "warnings", [
      %{"code" => "canary", "object" => @canary_cid, "reason" => "alert #{@canary_cid}"}
    ])
  end

  defp refute_canary(html) do
    refute html =~ @canary_handle
    refute html =~ @canary_name
    refute html =~ @canary_cid
    refute html =~ @canary_cid_encoded
    refute html =~ @canary_chat_id
    refute html =~ @canary_text
  end

  defp assert_canary_identity(html) do
    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_cid
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

  test "topology privacy masks ids and hashes avatar seeds while preserving canvas targets", %{
    conn: conn
  } do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, ~p"/topology?debug=1")

    _html = push_canary_snap(view)
    assert_push_event(view, "pipeline:agents", payload)

    expected_seed = :crypto.hash(:sha256, @canary_handle) |> Base.encode16(case: :lower)
    assert payload.handles["wingston_agent_0"] == expected_seed
    assert payload.sessions["wingston_agent_0"] == "inspect:0"
    assert payload.session_labels["wingston_agent_0"] == "tg:•••"
    refute inspect(payload) =~ @canary_handle
    refute inspect(payload) =~ @canary_cid

    html = push_canary_story(view)
    refute_canary(html)
    assert html =~ "•••"
    assert html =~ "thinking"
    assert html =~ "3.5s"

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {
      :display_event,
      %{
        "kind" => "routed",
        "cid" => @canary_cid,
        "slot" => "wingston_agent_0",
        "text" => @canary_text
      }
    })

    assert_push_event(view, "pipeline:event", event)
    refute inspect(event) =~ @canary_cid
    refute inspect(event) =~ @canary_text
    assert event["cid"] =~ "cid:"
    assert event["text"] == "▪▪▪▪▪"
  end

  test "topology privacy off keeps existing identity output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = push_canary_snap(view)
    assert_push_event(view, "pipeline:agents", payload)

    assert payload.handles["wingston_agent_0"] == @canary_handle
    assert payload.sessions["wingston_agent_0"] == @canary_cid
    assert_canary_identity(html)
  end

  test "sessions privacy masks row identity and shared inspector transcripts", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = push_canary_snap(view)
    refute_canary(html)
    assert html =~ "•••"
    assert html =~ "wingston_agent_0"
    assert html =~ "scout"

    view |> element(~s(tr[phx-value-session_id="inspect:0"])) |> render_click()
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    refute_canary(html)
    assert html =~ "▪▪▪▪▪"
    assert html =~ "Conversation"
  end

  test "sessions privacy off keeps row identity and inspector transcript output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = push_canary_snap(view)
    assert_canary_identity(html)

    view |> element(~s(tr[phx-value-session_id="#{@canary_cid}"])) |> render_click()
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    assert html =~ @canary_text
    assert_canary_identity(html)
  end

  test "session detail privacy masks header ids and conversation text", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/sessions/#{@canary_cid_encoded}")

    _html = push_canary_snap(view)
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    refute_canary(html)
    assert html =~ "▪▪▪▪▪"
    assert html =~ "wingston_agent_0"
    assert html =~ "telegram"
  end

  test "session detail privacy off keeps existing identity and transcript output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/sessions/#{@canary_cid_encoded}")

    _html = push_canary_snap(view)
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @canary_cid}, 500
    html = render(view)

    assert_canary_identity(html)
    assert html =~ @canary_text
    assert html =~ @canary_chat_id
  end

  test "events privacy masks story rows and raw engine event metadata", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/events")

    _html = push_canary_snap(view)

    html =
      push_story(view, canary_story(%{story: [canary_story_row()]}))

    refute_canary(html)
    assert html =~ "▪▪▪▪▪"

    {:ok, raw_view, _html} = live(conn, "/events?view=raw")
    html = render(raw_view)

    refute_canary(html)
    assert html =~ "info"
    assert html =~ "agent"
    assert html =~ "▪▪▪▪▪"
  end

  test "events privacy off keeps story and raw engine event output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/events")

    html = push_canary_snap(view)
    assert html =~ @canary_handle
    assert html =~ @canary_cid

    html = push_story(view, canary_story(%{story: [canary_story_row()]}))
    assert html =~ @canary_text
    assert html =~ @canary_cid_encoded

    {:ok, raw_view, _html} = live(conn, "/events?view=raw")
    html = render(raw_view)
    assert html =~ @canary_text
    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_chat_id
  end

  test "logs privacy suppresses raw slot output and masks session selector values", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/logs")
    html = push_canary_snap(view)

    refute_canary(html)
    assert html =~ "session 1"

    view |> element("form[phx-change='select']") |> render_change(%{"session_id" => "session:0"})
    assert_receive {:logs_loaded, @canary_cid}, 500
    html = render(view)

    refute_canary(html)
    assert html =~ "Raw slot output hidden in privacy mode."
    assert html =~ "1 line"
  end

  test "logs privacy off keeps raw selector ids and slot output", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/logs")
    html = push_canary_snap(view)

    assert html =~ @canary_cid
    view |> element("form[phx-change='select']") |> render_change(%{"session_id" => @canary_cid})
    assert_receive {:logs_loaded, @canary_cid}, 500
    html = render(view)

    assert html =~ @canary_text
    assert html =~ @canary_cid
  end

  test "overview privacy masks in-flight users, warnings, and issue text", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/")

    _html = push_canary_snap(view, canary_warning_snap())

    html =
      push_story(
        view,
        canary_story(%{
          issues: [canary_story_row(%{issue: true, text: @canary_text})],
          story: [canary_story_row(%{kind: "reply_sent", text: @canary_text})]
        })
      )

    refute_canary(html)
    assert html =~ "•••"
    assert html =~ "▪▪▪▪▪"
    assert html =~ "canary"
  end

  test "overview privacy off keeps warning ids and story labels", %{conn: conn} do
    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/")

    _html = push_canary_snap(view, canary_warning_snap())

    html =
      push_story(
        view,
        canary_story(%{
          issues: [canary_story_row(%{issue: true, text: @canary_text})],
          story: [canary_story_row(%{kind: "reply_sent", text: @canary_text})]
        })
      )

    assert html =~ @canary_handle
    assert html =~ @canary_cid
    assert html =~ @canary_text
  end

  test "usage privacy masks router rows and host usage tiles", %{conn: conn} do
    RouterUsageCache.put("all", {:ok, canary_usage()})
    stub(RouterClientMock, :usage, fn _ -> {:ok, canary_usage()} end)

    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/usage")

    html = push_canary_snap(view, canary_usage_snap())

    refute_canary(html)
    assert html =~ "42"
    assert html =~ "▪▪▪▪▪"
  end

  test "usage privacy off keeps router rows and host usage tile strings", %{conn: conn} do
    RouterUsageCache.put("all", {:ok, canary_usage()})
    stub(RouterClientMock, :usage, fn _ -> {:ok, canary_usage()} end)

    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/usage")

    html = push_canary_snap(view, canary_usage_snap())

    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_cid
    assert html =~ @canary_chat_id
    assert html =~ @canary_text
  end

  test "config privacy masks identity-bearing values", %{conn: conn} do
    stub(SwarmClientMock, :config, fn _ -> {:ok, canary_config()} end)

    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/config")
    html = render(view)

    refute_canary(html)
    assert html =~ "sender"
    assert html =~ "•••"
    assert html =~ "tg:•••"
  end

  test "config privacy off keeps identity-bearing values", %{conn: conn} do
    stub(SwarmClientMock, :config, fn _ -> {:ok, canary_config()} end)

    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/config")
    html = render(view)

    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_cid
  end

  test "extension page privacy masks arbitrary extension payloads", %{conn: conn} do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, canary_extension_snap()} end)

    conn = init_test_session(conn, %{privacy: true})
    {:ok, view, _html} = live(conn, "/extensions/canary-report")
    html = push_canary_snap(view, canary_extension_snap())

    refute_canary(html)
    assert html =~ "7"
    assert html =~ "•••"
  end

  test "extension page privacy off keeps arbitrary extension payloads", %{conn: conn} do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, canary_extension_snap()} end)

    conn = init_test_session(conn, %{privacy: false})
    {:ok, view, _html} = live(conn, "/extensions/canary-report")
    html = push_canary_snap(view, canary_extension_snap())

    assert html =~ @canary_handle
    assert html =~ @canary_name
    assert html =~ @canary_cid
    assert html =~ @canary_text
  end
end
