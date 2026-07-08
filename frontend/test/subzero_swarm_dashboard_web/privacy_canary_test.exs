defmodule SubzeroSwarmDashboardWeb.PrivacyCanaryTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{RouterClientMock, RouterUsageCache, SwarmClientMock}

  setup :set_mox_global

  @handle "canary_h4ndle"
  @name "Canary Q. Name"
  @label "@canary_h4ndle"
  @cid "tg:987654321:0"
  @group_cid "tg:-1009876543210:7"
  @user_id 987_654_321
  @raw_user_id "987654321"
  @text "CANARY-TEXT"
  @cid_encoded Base.url_encode64(@cid, padding: false)
  @group_cid_encoded Base.url_encode64(@group_cid, padding: false)

  @fixture %{
    snapshot: %{
      "swarm" => "wingston",
      "dashboard_title" => "Wingston Canary",
      "status" => "running",
      "generated_at" => "2026-07-08T12:00:00Z",
      "summary" => %{
        "agents" => 2,
        "objects" => 3,
        "pool" => %{"size" => 4, "leased" => 2, "idle" => 2}
      },
      "nodes" => [
        %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
        %{
          "name" => "wingston_agent_0",
          "type" => "agent",
          "state" => "active",
          "session_id" => @cid
        },
        %{
          "name" => "wingston_agent_1",
          "type" => "agent",
          "state" => "active",
          "session_id" => @group_cid
        }
      ],
      "edges" => [
        %{"from" => "ingress", "to" => "wingston_agent_0"},
        %{"from" => "ingress", "to" => "wingston_agent_1"}
      ],
      "sessions" => [
        %{
          "session_id" => @cid,
          "transport" => "telegram",
          "agent" => "wingston_agent_0",
          "state" => "active",
          "last_activity" => "2026-07-08T12:00:00Z",
          "label" => @label,
          "transport_ref" => %{"chat_id" => @raw_user_id, "thread_id" => "0"},
          "metadata" => %{"chat_type" => "dm"},
          "user" => %{"handle" => @handle, "name" => @name, "user_id" => @user_id}
        },
        %{
          "session_id" => @group_cid,
          "transport" => "telegram",
          "agent" => "wingston_agent_1",
          "state" => "active",
          "last_activity" => "2026-07-08T12:00:03Z",
          "label" => "group #{@group_cid}",
          "transport_ref" => %{"chat_id" => "-1009876543210", "thread_id" => "7"},
          "metadata" => %{"chat_type" => "group"},
          "user" => %{"handle" => @handle, "name" => @name, "user_id" => @user_id}
        }
      ],
      "extensions" => %{
        "consumers" => %{
          "count" => 2,
          "items" => [
            %{
              "session_id" => @cid,
              "label" => @label,
              "user_id" => @user_id,
              "mode" => "scout",
              "opt_out" => false
            },
            %{
              "session_id" => @group_cid,
              "label" => "group #{@group_cid}",
              "user_id" => @user_id,
              "mode" => "announce",
              "opt_out" => true
            }
          ]
        },
        "metrics_today" => %{"day" => "2026-07-08", "replies" => 1},
        "usage_tiles" => [
          %{"label" => @label, "value" => @text, "sub" => "#{@cid} #{@group_cid}"}
        ],
        "dashboard_pages" => [
          %{
            "id" => "canary-consumers",
            "label" => @label,
            "meta" => "#{@cid} #{@group_cid}",
            "sections" => [
              %{
                "type" => "metrics",
                "title" => "Consumers",
                "items" => [
                  %{"label" => "owner", "value" => @name, "sub" => @cid},
                  %{"label" => "group", "value" => @group_cid, "sub" => @label}
                ]
              },
              %{
                "type" => "table",
                "title" => "Consumers",
                "columns" => [
                  %{"key" => "label", "label" => "label"},
                  %{"key" => "handle", "label" => "handle"},
                  %{"key" => "name", "label" => "name"},
                  %{"key" => "user_id", "label" => "user id"},
                  %{"key" => "cid", "label" => "cid", "mono" => true},
                  %{"key" => "group_cid", "label" => "group cid", "mono" => true},
                  %{"key" => "message", "label" => "message"}
                ],
                "rows" => [
                  %{
                    "label" => @label,
                    "handle" => @handle,
                    "name" => @name,
                    "user_id" => @user_id,
                    "cid" => @cid,
                    "group_cid" => @group_cid,
                    "message" => @text
                  }
                ]
              }
            ]
          }
        ]
      },
      "warnings" => [
        %{
          "code" => "canary",
          "object" => @cid,
          "reason" => "cid route #{@cid} mirrored to #{@group_cid}"
        }
      ]
    },
    story: %{
      feed_status: :ok,
      feed_age_s: 0,
      baseline_at: ~U[2026-07-08 12:00:00Z],
      in_flight: [
        %{
          cid: @cid,
          user: @handle,
          agent: "wingston_agent_0",
          count: 1,
          opened_at: 1.0,
          elapsed_s: 3.5,
          stalled: false,
          activity: "thinking"
        }
      ],
      agents: [],
      kpis: %{replies: 1},
      issues: [
        %{
          seq: 985,
          ts: 1_782_000_000.0,
          kind: "warning",
          cid: @cid,
          agent: "wingston_agent_0",
          issue: true,
          text: "#{@text} #{@cid} #{@group_cid}"
        }
      ],
      story: [
        %{
          seq: 986,
          ts: 1_782_000_001.0,
          kind: "request_open",
          cid: @cid,
          agent: "wingston_agent_0",
          issue: false,
          text: "#{@text} from #{@cid} via #{@label}"
        },
        %{
          seq: 987,
          ts: 1_782_000_002.0,
          kind: "routed",
          cid: @group_cid,
          agent: "wingston_agent_1",
          issue: false,
          text: "#{@text} group #{@group_cid} for #{@handle}"
        }
      ]
    },
    event: %{
      "timestamp" => "2026-07-08T12:00:00Z",
      "level" => "info",
      "category" => "agent",
      "agent" => "wingston_agent_0",
      "message" => "#{@text} #{@cid} #{@group_cid} #{@handle}",
      "metadata" => %{
        "cid" => @cid,
        "group_cid" => @group_cid,
        "chat_id" => @raw_user_id,
        "user" => %{"handle" => @handle, "name" => @name, "user_id" => @user_id}
      }
    },
    display_event: %{
      "kind" => "routed",
      "cid" => @cid,
      "session_id" => @cid,
      "conversation_id" => @group_cid,
      "handle" => @handle,
      "label" => @label,
      "message" => "#{@text} #{@cid} #{@group_cid} #{@handle}",
      "slot" => "wingston_agent_0"
    },
    usage: %{
      "schema_version" => 2,
      "detail_level" => "full",
      "totals" => %{
        "requests" => 2,
        "tokens_total" => 42,
        "tokens_in" => 20,
        "tokens_out" => 22,
        "errors" => 1,
        "error_rate" => 0.5,
        "latency_ms_avg" => 12,
        "latency_ms_max" => 20
      },
      "by_route" => %{
        @cid => %{"requests" => 1, "tokens_total" => 21, "errors" => 0},
        @group_cid => %{"requests" => 1, "tokens_total" => 21, "errors" => 1}
      },
      "by_provider" => %{"openai" => %{"requests" => 2, "tokens_total" => 42}},
      "by_served_model" => %{"gpt-canary" => %{"requests" => 2, "tokens_total" => 42}},
      "by_model_family" => %{"test" => %{"requests" => 2, "tokens_total" => 42}},
      "consumer_settings" => %{
        "status" => "active",
        "allowed_routes" => [@cid, @group_cid],
        "effective_per_min" => 60
      },
      "key" => %{"sha256_prefix" => "ab12cd34", "status" => "active"},
      "health_summary" => %{
        "state" => "degraded",
        "success_rate" => 0.5,
        "status_counts" => %{"200" => 1, "500" => 1}
      },
      "route_health" => [
        %{"route" => @cid, "state" => "healthy"},
        %{"route" => @group_cid, "state" => "degraded"}
      ],
      "recent" => [
        %{
          "ts" => 1_782_000_000,
          "status" => 500,
          "served_model_id" => "gpt-canary",
          "path" => "/v1/chat/#{@cid}/#{@group_cid}",
          "latency_ms" => 12,
          "tokens_total" => 42,
          "error_message" => "#{@text} #{@cid} #{@group_cid}",
          "user_id" => @user_id
        }
      ],
      "security" => %{"sanitized" => true}
    },
    config: %{
      "objects" => [
        %{
          "name" => "sender",
          "handler" => "Sender",
          "has_schema" => true,
          "config" => [
            %{
              "key" => "alert_cids",
              "value" => [@cid, @group_cid],
              "description" => "delivery routes #{@cid} #{@group_cid}",
              "mutable" => true,
              "secret" => false
            },
            %{
              "key" => "owner_handle",
              "value" => @handle,
              "description" => "operator handle",
              "mutable" => false,
              "secret" => false
            },
            %{
              "key" => "display_name",
              "value" => @name,
              "description" => "operator name",
              "mutable" => false,
              "secret" => false
            },
            %{
              "key" => "consumer_label",
              "value" => @label,
              "description" => "adapter label",
              "mutable" => false,
              "secret" => false
            }
          ]
        }
      ]
    },
    history: %{
      "session_id" => @cid,
      "source" => "store",
      "turns" => [
        %{"role" => "user", "content" => @text, "at" => 1_782_000_000},
        %{"role" => "assistant", "content" => "reply #{@text}", "at" => 1_782_000_060}
      ]
    },
    logs: %{
      "source" => "agent_server",
      "logs" => [
        %{
          "timestamp" => "2026-07-08T12:00:00Z",
          "role" => "user",
          "content" => "#{@text} #{@cid} #{@group_cid}"
        }
      ]
    }
  }

  setup do
    parent = self()

    try do
      Agent.update(RouterUsageCache, fn _ -> %{} end)
    catch
      :exit, _ -> :ok
    end

    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, fixture(:snapshot)} end)
    stub(SwarmClientMock, :events, fn _, _ -> {:ok, [fixture(:event)]} end)
    stub(SwarmClientMock, :config, fn _ -> {:ok, fixture(:config)} end)
    stub(RouterClientMock, :usage, fn _ -> {:ok, fixture(:usage)} end)

    stub(SwarmClientMock, :session_history, fn _, sid ->
      send(parent, {:history_loaded, sid})
      {:ok, Map.put(fixture(:history), "session_id", sid)}
    end)

    stub(SwarmClientMock, :session_logs, fn _, sid ->
      send(parent, {:logs_loaded, sid})
      {:ok, fixture(:logs)}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
    end)

    :ok
  end

  test "overview privacy on hides all canary strings and keeps the badge" do
    html = overview_html(true)

    assert_privacy_badge(html, "overview")
    refute_canary(html, "overview")
  end

  test "overview privacy off proves the canary fixture is wired" do
    html = overview_html(false)

    assert_canary_present(html, "overview")
  end

  test "topology privacy on hides canary strings in html and pushed canvas payloads" do
    html = topology_html(true)

    assert_privacy_badge(html, "topology")
    refute_canary(html, "topology html")
  end

  test "topology privacy off proves the canary fixture is wired" do
    html = topology_html(false)

    assert_canary_present(html, "topology")
  end

  test "sessions privacy on hides all canary strings and keeps the badge" do
    html = sessions_html(true)

    assert_privacy_badge(html, "sessions")
    refute_canary(html, "sessions")
  end

  test "sessions privacy off proves the canary fixture is wired" do
    html = sessions_html(false)

    assert_canary_present(html, "sessions")
  end

  test "session detail privacy on hides all canary strings and keeps the badge" do
    html = session_detail_html(true)

    assert_privacy_badge(html, "session detail")
    refute_canary(html, "session detail")
  end

  test "session detail privacy off proves the canary fixture is wired" do
    html = session_detail_html(false)

    assert_canary_present(html, "session detail")
  end

  test "events privacy on hides story and raw engine canaries and keeps the badge" do
    {story_html, raw_html} = events_html(true)

    assert_privacy_badge(story_html, "events story")
    assert_privacy_badge(raw_html, "events raw")
    refute_canary(story_html <> raw_html, "events")
  end

  test "events privacy off proves the canary fixture is wired" do
    {story_html, raw_html} = events_html(false)

    assert_canary_present(story_html <> raw_html, "events")
  end

  test "logs privacy on hides all canary strings and keeps the badge" do
    html = logs_html(true)

    assert_privacy_badge(html, "logs")
    refute_canary(html, "logs")
  end

  test "logs privacy off proves the canary fixture is wired" do
    html = logs_html(false)

    assert_canary_present(html, "logs")
  end

  test "usage privacy on hides all canary strings and keeps the badge" do
    html = usage_html(true)

    assert_privacy_badge(html, "usage")
    refute_canary(html, "usage")
  end

  test "usage privacy off proves the canary fixture is wired" do
    html = usage_html(false)

    assert_canary_present(html, "usage")
  end

  test "config privacy on hides all canary strings and keeps the badge" do
    html = config_html(true)

    assert_privacy_badge(html, "config")
    refute_canary(html, "config")
  end

  test "config privacy off proves the canary fixture is wired" do
    html = config_html(false)

    assert_canary_present(html, "config")
  end

  test "extension page privacy on hides all canary strings and keeps the badge" do
    html = extension_html(true)

    assert_privacy_badge(html, "extension")
    refute_canary(html, "extension")
  end

  test "extension page privacy off proves the canary fixture is wired" do
    html = extension_html(false)

    assert_canary_present(html, "extension")
  end

  defp overview_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/")
    push_snapshot(view)
    push_story(view)
  end

  defp topology_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/topology?debug=1")

    push_snapshot(view)
    assert_push_event(view, "pipeline:agents", payload)

    if privacy? do
      expected_seed = :crypto.hash(:sha256, @handle) |> Base.encode16(case: :lower)

      assert payload.handles["wingston_agent_0"] == expected_seed
      assert payload.sessions["wingston_agent_0"] == "inspect:0"
      assert payload.session_labels["wingston_agent_0"] == "tg:•••"
      refute_canary(payload, "topology agents payload")
    else
      assert payload.handles["wingston_agent_0"] == @handle
      assert payload.sessions["wingston_agent_0"] == @cid
      assert_canary_present(payload, "topology agents payload")
    end

    html = push_story(view)

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {
      :display_event,
      fixture(:display_event)
    })

    assert_push_event(view, "pipeline:event", event)

    if privacy? do
      assert event["cid"] =~ "cid:"
      assert event["session_id"] == "tg:•••"
      assert event["conversation_id"] == "tg:•••"
      assert event["message"] == "▪▪▪▪▪"
      refute_canary(event, "topology event payload")
    else
      assert_canary_present(event, "topology event payload")
    end

    html
  end

  defp sessions_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/sessions")

    push_snapshot(view)
    push_story(view)

    selector =
      if privacy?,
        do: ~s(tr[phx-value-session_id="inspect:0"]),
        else: ~s(tr[phx-value-session_id="#{@cid}"])

    view |> element(selector) |> render_click()
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @cid}, 500

    render(view)
  end

  defp session_detail_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/sessions/#{@cid_encoded}")

    push_snapshot(view)
    push_story(view)
    render_click(view, "transcripts_reveal", %{})
    assert_receive {:history_loaded, @cid}, 500

    render(view)
  end

  defp events_html(privacy?) do
    {:ok, story_view, _html} = live(conn_with_privacy(privacy?), "/events")
    push_snapshot(story_view)
    story_html = push_story(story_view)

    {:ok, raw_view, _html} = live(conn_with_privacy(privacy?), "/events?view=raw")
    push_snapshot(raw_view)
    raw_html = render(raw_view)

    {story_html, raw_html}
  end

  defp logs_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/logs")

    push_snapshot(view)

    selected = if privacy?, do: "session:0", else: @cid
    view |> element("form[phx-change='select']") |> render_change(%{"session_id" => selected})
    assert_receive {:logs_loaded, @cid}, 500

    render(view)
  end

  defp usage_html(privacy?) do
    RouterUsageCache.put("all", {:ok, fixture(:usage)})

    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/usage")
    push_snapshot(view)
  end

  defp config_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/config")
    render(view)
  end

  defp extension_html(privacy?) do
    {:ok, view, _html} = live(conn_with_privacy(privacy?), "/extensions/canary-consumers")
    push_snapshot(view)
  end

  defp conn_with_privacy(privacy?) do
    build_conn()
    |> init_test_session(%{privacy: privacy?})
  end

  defp push_snapshot(view) do
    Phoenix.PubSub.broadcast(
      SubzeroSwarmDashboard.PubSub,
      "feed",
      {:snapshot, fixture(:snapshot)}
    )

    render(view)
  end

  defp push_story(view) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {:story, fixture(:story)})
    render(view)
  end

  defp fixture(key), do: Map.fetch!(@fixture, key)

  defp forbidden_strings do
    [
      @handle,
      @name,
      @raw_user_id,
      @cid,
      @group_cid,
      @text,
      @cid_encoded,
      @group_cid_encoded
    ]
  end

  defp assert_privacy_badge(html, context) do
    assert html =~ ~s(data-privacy="on"), "#{context} did not render privacy-on chrome"
    assert html =~ ~s(id="privacy-badge"), "#{context} did not render the privacy badge"
  end

  defp refute_canary(value, context) do
    haystack = haystack(value)

    Enum.each(forbidden_strings(), fn needle ->
      refute haystack =~ needle,
             "#{context} leaked #{inspect(needle)} in #{String.slice(haystack, 0, 1_500)}"
    end)
  end

  defp assert_canary_present(value, context) do
    haystack = haystack(value)

    assert Enum.any?(forbidden_strings(), &String.contains?(haystack, &1)),
           "#{context} did not render any canary string"
  end

  defp haystack(value) when is_binary(value), do: value
  defp haystack(value), do: inspect(value)
end
