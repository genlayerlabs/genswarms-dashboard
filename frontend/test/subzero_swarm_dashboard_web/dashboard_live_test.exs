defmodule SubzeroSwarmDashboardWeb.DashboardLiveTest do
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias SubzeroSwarmDashboard.{SwarmClientMock, RouterClientMock}
  alias SubzeroSwarmDashboardWeb.ExtensionPages

  setup :set_mox_global

  @snap %{
    "swarm" => "wingston",
    "dashboard_title" => "Wingston",
    "status" => "running",
    "uptime_s" => 5821,
    "data_source" => "in_process",
    "generated_at" => "2026-06-03T15:22:01Z",
    "summary" => %{
      "agents" => 1,
      "objects" => 6,
      "pool" => %{"size" => 2048, "leased" => 1, "idle" => 2047}
    },
    "nodes" => [
      %{"name" => "ingress", "type" => "object", "subtype" => "ingress"},
      %{"name" => "policy", "type" => "object", "subtype" => "policy"},
      %{
        "name" => "wingston_agent_0",
        "type" => "agent",
        "state" => "active",
        "session_id" => "tg:1:0"
      }
    ],
    "edges" => [%{"from" => "ingress", "to" => "policy"}],
    "sessions" => [
      %{
        "session_id" => "tg:1:0",
        "transport" => "telegram",
        "agent" => "wingston_agent_0",
        "state" => "active",
        "last_activity" => "2026-06-03T15:22:01Z",
        "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"},
        "metadata" => %{"chat_type" => "dm"}
      }
    ],
    "extensions" => %{
      "consumers" => %{
        "count" => 1,
        "items" => [%{"session_id" => "tg:1:0", "mode" => "scout", "opt_out" => false}]
      }
    },
    "warnings" => []
  }

  setup do
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)

    stub(SwarmClientMock, :session_history, fn _, _ ->
      {:ok, %{"session_id" => "tg:1:0", "turns" => [], "source" => "unavailable"}}
    end)

    stub(SwarmClientMock, :events, fn _, _ -> {:ok, []} end)

    stub(SwarmClientMock, :session_logs, fn _, _ ->
      {:ok, %{"logs" => [], "source" => "unavailable"}}
    end)

    stub(SwarmClientMock, :session_skills, fn _, _ ->
      {:ok, %{"skills" => [], "source" => "unavailable"}}
    end)

    stub(RouterClientMock, :usage, fn _ -> {:unavailable, :not_configured} end)
    :ok
  end

  defp push_snap(view, snap \\ @snap) do
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    render(view)
  end

  test "overview renders the snapshot", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Overview"
    html = push_snap(view)
    assert html =~ "in_process"
    assert html =~ "2048"
  end

  test "overview renders the inbox queue tile when the host publishes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "events", {
      :story,
      %{
        feed_status: :ok,
        feed_age_s: 0,
        baseline_at: DateTime.utc_now(),
        in_flight: [],
        agents: [],
        kpis: %{},
        issues: [],
        story: []
      }
    })

    snap =
      put_in(@snap, ["extensions", "inbox_queue"], %{
        "depth" => 23,
        "oldest_seconds" => 240
      })

    html = push_snap(view, snap)

    assert html =~ "23"
    assert html =~ "oldest 4m"
  end

  test "layout renders the host-provided dashboard title from the snapshot", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = push_snap(view, Map.put(@snap, "dashboard_title", "Wingston Ops"))

    assert html =~ "Wingston Ops"
  end

  test "topology mounts and lists nodes in the fallback table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/topology")
    assert html =~ "Topology"
    assert push_snap(view) =~ "ingress"
  end

  test "snapshot pushes the dynamic agent slots to the pipeline hook", %{conn: conn} do
    {:ok, view, _} = live(conn, "/topology")
    push_snap(view)
    assert_push_event(view, "pipeline:agents", %{agents: ["wingston_agent_0"]})
  end

  test "a display event reaches the pipeline hook (and crashes no page)", %{conn: conn} do
    {:ok, topo, _} = live(conn, "/topology")
    {:ok, overview, _} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      SubzeroSwarmDashboard.PubSub,
      "events",
      {:display_event,
       %{"kind" => "reply_sent", "cid" => "tg:1:0", "ok" => true, "seq" => 7, "ts" => 1.0}}
    )

    # Topology forwards it to the hook; other pages safely ignore it (catch-all).
    assert_push_event(topo, "pipeline:event", %{"kind" => "reply_sent", "cid" => "tg:1:0"})

    assert render(overview) =~ "Overview"
  end

  test "sessions lists from the snapshot", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    html = push_snap(view)
    assert html =~ "tg:1:0"
    # the agent slot appears only in the sessions row (not the consumers panel).
    assert html =~ "wingston_agent_0"
  end

  test "sessions search filters by session_id / transport_ref", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)
    # the agent slot is rendered only in the sessions table row, so it's a clean
    # signal that the row itself is shown (the consumers panel omits the agent).
    assert render(view) =~ "wingston_agent_0"

    assert view |> element("form[phx-change='search']") |> render_change(%{"q" => "999999"}) =~
             "No sessions match"

    refute view |> element("form[phx-change='search']") |> render_change(%{"q" => "999999"}) =~
             "wingston_agent_0"

    assert view |> element("form[phx-change='search']") |> render_change(%{"q" => "1"}) =~
             "wingston_agent_0"
  end

  test "sessions lead with the user handle + name when known", %{conn: conn} do
    snap =
      put_in(@snap, ["sessions"], [
        %{
          "session_id" => "tg:1:0",
          "transport" => "telegram",
          "agent" => "wingston_agent_0",
          "state" => "active",
          "last_activity" => "2026-06-03T15:22:01Z",
          "transport_ref" => %{"chat_id" => "1", "thread_id" => "0"},
          "metadata" => %{"chat_type" => "dm"},
          "user" => %{"handle" => "alberto", "name" => "Alberto C"}
        }
      ])

    {:ok, view, _} = live(conn, "/sessions")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    assert html =~ "@alberto"
    assert html =~ "Alberto C"
  end

  test "sessions show a reply-health badge from the sender's deliveries extension", %{conn: conn} do
    # reply-health classifies against the REAL clock, so the inbound must be
    # recent: fresh enough to be :unanswered (not :stale), old enough to be
    # past the 120s pending grace.
    recent = DateTime.utc_now() |> DateTime.add(-3600, :second)
    recent_iso = DateTime.to_iso8601(recent)
    in_unix = DateTime.to_unix(recent)
    snap = put_in(@snap, ["sessions", Access.at(0), "last_activity"], recent_iso)

    {:ok, view, _} = live(conn, "/sessions")

    # answered: a delivery AFTER the last inbound
    answered =
      put_in(snap, ["extensions", "deliveries"], %{
        "items" => [%{"session_id" => "tg:1:0", "at" => in_unix + 10, "status" => "sent"}]
      })

    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, answered})
    assert render(view) =~ "answered"

    # unanswered: recent inbound, no delivery -> alarm badge with the waiting
    # time + counted in the clickable facet chip
    unanswered = put_in(snap, ["extensions", "deliveries"], %{"items" => []})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, unanswered})
    html = render(view)
    assert html =~ "no reply · 1h"
    assert html =~ "unanswered"
  end

  test "sessions: an unanswered row older than 48h decays to stale (no alarm)", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")

    # @snap's last_activity is 2026-06-03 — long past the 48h decay window
    stale = put_in(@snap, ["extensions", "deliveries"], %{"items" => []})
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, stale})
    html = render(view)

    assert html =~ "stale"
    assert html =~ "no reply"
    # the warning facet only renders when something is FRESH-unanswered
    refute html =~ "⚠ unanswered"
  end

  test "sessions: facet chips filter the table and the cap hides the long tail", %{conn: conn} do
    now = DateTime.utc_now()

    mk = fn n, state ->
      %{
        "session_id" => "tg:#{n}:0",
        "transport" => "telegram",
        "state" => state,
        "last_activity" => now |> DateTime.add(-60 - n, :second) |> DateTime.to_iso8601(),
        "transport_ref" => %{"chat_id" => "#{n}", "thread_id" => "0"},
        "metadata" => %{"chat_type" => "dm"}
      }
    end

    sessions = [mk.(9000, "active") | Enum.map(1..60, &mk.(&1, "idle"))]

    snap =
      @snap
      |> put_in(["sessions"], sessions)
      |> put_in(["extensions", "deliveries"], %{"items" => []})

    {:ok, view, _} = live(conn, "/sessions")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    # 61 rows > the 50-row cap: the tail hides behind one "show more" row
    assert html =~ "show 11 more"
    assert view |> element("tr td button", "show 11 more") |> render_click() =~ "show fewer"

    # the "live" facet narrows to the one active session
    html = view |> element("button[phx-value-f='live']") |> render_click()
    assert html =~ "tg:9000:0"
    refute html =~ "show 11 more"
    refute html =~ "tg:1:0\n"
  end

  test "clicking a session opens the shared inspector, Esc-close clears it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    push_snap(view)

    html = view |> element("tr[phx-value-session_id='tg:1:0']") |> render_click()
    # Conversation FIRST: the saved user↔assistant exchange is the inspector's
    # main content; the slot's raw working log sits collapsed behind an
    # "agent activity" disclosure (rendered once the async load lands).
    assert html =~ "Conversation"
    assert html =~ "tg:1:0"

    refute view |> element("button[aria-label='Close']") |> render_click() =~ "Conversation"
  end

  test "session detail loads a transcript", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sessions/tg:1:0")
    assert html =~ "Conversation"
  end

  test "session detail renders the per-session activity timeline from session_logs", %{conn: conn} do
    stub(SwarmClientMock, :session_logs, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "agent_server",
         "logs" => [
           %{"timestamp" => "2026-06-04T10:00:00Z", "role" => "user", "content" => "ping"},
           %{"timestamp" => "2026-06-04T10:00:01Z", "role" => "assistant", "content" => "pong"}
         ]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    # activity is behind the transcript gate — reveal explicitly (like the
    # sibling tests) instead of depending on ambient gate state, which made
    # this test order-dependent across seeds
    render_click(view, "transcripts_reveal", %{})
    html = render(view)

    assert html =~ "Agent activity"
    assert html =~ "agent_server"
    assert html =~ "ping"
    assert html =~ "pong"
    assert html =~ "2026-06-04T10:00:01Z"
  end

  test "session detail renders the live slot's skills as the system-prompt block", %{conn: conn} do
    stub(SwarmClientMock, :session_skills, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "slot",
         "skills" => [%{"name" => "browse.md", "content" => "# Browse\nRender pages."}]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "System prompt · skills"
    assert html =~ "browse.md"
    assert html =~ "Render pages."
    # leased slot ⇒ no pool-fallback note
    refute html =~ "isn&#39;t leased to a slot right now"
  end

  test "session detail notes the pool fallback when the session isn't leased", %{conn: conn} do
    stub(SwarmClientMock, :session_skills, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "pool",
         "skills" => [%{"name" => "browse.md", "content" => "# Browse\nRender pages."}]
       }}
    end)

    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "System prompt · skills"
    assert html =~ "Render pages."
    assert html =~ "isn&#39;t leased to a slot right now"
  end

  test "session detail says skills are unavailable when no live agent exists at all", %{
    conn: conn
  } do
    # default session_skills stub is source: unavailable
    {:ok, view, _} = live(conn, "/sessions/tg:1:0")
    html = render(view)

    assert html =~ "System prompt · skills"
    assert html =~ "Unavailable (no live agent"
  end

  test "events page mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/events")
    assert html =~ "Events"
  end

  # the LogStore table is the "engine raw" view, demoted behind the story toggle
  test "events: server filters pass through + client contains filter narrows rows", %{conn: conn} do
    parent = self()

    stub(SwarmClientMock, :events, fn _swarm, opts ->
      send(parent, {:events_opts, opts})

      {:ok,
       [
         %{
           "timestamp" => "t1",
           "level" => "info",
           "category" => "agent",
           "agent" => "a0",
           "message" => "spawned agent"
         },
         %{
           "timestamp" => "t2",
           "level" => "error",
           "category" => "router",
           "agent" => "r",
           "message" => "invalid route"
         }
       ]}
    end)

    {:ok, view, _} = live(conn, "/events?view=raw")
    assert render(view) =~ "spawned agent"

    # server-side filters reach SwarmClient.events
    view
    |> element("#raw-filter-form")
    |> render_change(%{
      "level" => "error",
      "category" => "router",
      "agent" => "r",
      "minutes" => "60"
    })

    assert_receive {:events_opts, %{level: "error", category: "router", agent: "r", minutes: 60}}

    # client-side "contains" narrows the rendered rows
    html = view |> element("#raw-filter-form") |> render_change(%{"contains" => "invalid"})
    assert html =~ "invalid route"
    refute html =~ "spawned agent"
  end

  test "usage shows unavailable when the router has no usage endpoint", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/usage")
    assert html =~ "Usage"
  end

  test "extension page registry validates ids and caps page payloads" do
    sections = Enum.map(1..13, &%{"type" => "text", "title" => "Section #{&1}"})

    pages =
      [%{"id" => "../bad", "label" => "Bad"}] ++
        Enum.map(1..14, fn n ->
          %{
            "id" => "page-#{n}",
            "label" => String.duplicate("L", 80),
            "sections" => sections
          }
        end)

    normalized = ExtensionPages.pages(%{"extensions" => %{"dashboard_pages" => pages}})

    assert length(normalized) == 12
    refute Enum.any?(normalized, &(&1["id"] == "../bad"))
    assert hd(normalized)["label"] == String.duplicate("L", 40)
    assert length(hd(normalized)["sections"]) == 12
  end

  test "extension pages register nav and render declarative metrics and bounded tables", %{
    conn: conn
  } do
    rows =
      Enum.map(1..101, fn n ->
        %{"name" => "item-#{n}", "score" => n / 10}
      end)

    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "custom-report",
          "label" => "Custom report",
          "icon" => "hero-puzzle-piece",
          "sections" => [
            %{
              "type" => "metrics",
              "title" => "Summary",
              "items" => [%{"label" => "Ratio", "value" => 0.125}]
            },
            %{
              "type" => "table",
              "title" => "Items",
              "columns" => [
                %{"key" => "name", "label" => "name"},
                %{"key" => "score", "label" => "score", "align" => "right"}
              ],
              "rows" => rows
            }
          ]
        }
      ])

    {:ok, overview, _} = live(conn, "/")
    assert push_snap(overview, snap) =~ "Custom report"

    {:ok, page, _} = live(conn, "/extensions/custom-report")
    html = push_snap(page, snap)
    assert html =~ "Custom report"
    assert html =~ "Ratio"
    assert html =~ "0.125"
    assert html =~ "item-100"
    refute html =~ "item-101"
  end

  test "extension tables sort numerically on header click and toggle direction", %{conn: conn} do
    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "sortable",
          "label" => "Sortable",
          "sections" => [
            %{
              "type" => "table",
              "title" => "Money",
              "columns" => [
                %{"key" => "name", "label" => "name"},
                %{"key" => "spent", "label" => "spent"}
              ],
              "rows" => [
                %{"name" => "mid", "spent" => "$2.00"},
                %{"name" => "low", "spent" => "$0.50"},
                %{"name" => "high", "spent" => "$10.00"}
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/sortable")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    render(view)

    # "$10.00" must sort as 10 (numeric), not "1..." (text)
    html = view |> element("button[phx-value-key='spent']") |> render_click()
    assert :binary.match(html, "low") |> elem(0) < :binary.match(html, "mid") |> elem(0)
    assert :binary.match(html, "mid") |> elem(0) < :binary.match(html, "high") |> elem(0)
    assert html =~ "↑"

    html = view |> element("button[phx-value-key='spent']") |> render_click()
    assert :binary.match(html, "high") |> elem(0) < :binary.match(html, "mid") |> elem(0)
    assert html =~ "↓"
  end

  test "extension rows carrying _cid open the shared inspector; the cid never renders", %{
    conn: conn
  } do
    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "clickable",
          "label" => "Clickable",
          "sections" => [
            %{
              "type" => "table",
              "title" => "Users",
              "columns" => [%{"key" => "user", "label" => "user"}],
              "rows" => [
                %{"user" => "@alberto", "_cid" => "tg:1:0"},
                %{"user" => "unmapped"}
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/clickable")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    # metadata channel: used for the click target, never rendered as content
    refute html =~ "_cid"

    html = view |> element(~s(tr[phx-value-session_id="tg:1:0"])) |> render_click()
    assert html =~ "Conversation"
  end

  test "tabs section renders the active tab only and switches on click", %{conn: conn} do
    tab_table = fn suffix ->
      %{
        "type" => "table",
        "title" => "Users " <> suffix,
        "columns" => [%{"key" => "user", "label" => "user"}],
        "rows" => [%{"user" => "row-" <> suffix}]
      }
    end

    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "tabbed",
          "label" => "Tabbed",
          "sections" => [
            %{
              "type" => "tabs",
              "title" => "Users by period",
              "tabs" => [
                %{"label" => "Today", "section" => tab_table.("today")},
                %{"label" => "All-time", "section" => tab_table.("alltime")}
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/tabbed")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    # first tab is active by default; the other tab's rows are NOT in the DOM
    assert html =~ "Today"
    assert html =~ "row-today"
    refute html =~ "row-alltime"

    html = view |> element(~s(button[phx-value-tab="1"][phx-value-sec="0"])) |> render_click()
    assert html =~ "row-alltime"
    refute html =~ "row-today"
  end

  test "sorting inside a tab table is scoped to that tab", %{conn: conn} do
    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "tab-sort",
          "label" => "TabSort",
          "sections" => [
            %{
              "type" => "tabs",
              "tabs" => [
                %{"label" => "Empty", "section" => %{"type" => "text", "body" => "nothing"}},
                %{
                  "label" => "Money",
                  "section" => %{
                    "type" => "table",
                    "title" => "Money",
                    "columns" => [
                      %{"key" => "name", "label" => "name"},
                      %{"key" => "spent", "label" => "spent"}
                    ],
                    "rows" => [
                      %{"name" => "mid", "spent" => "$2.00"},
                      %{"name" => "low", "spent" => "$0.50"},
                      %{"name" => "high", "spent" => "$10.00"}
                    ]
                  }
                }
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/tab-sort")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    render(view)

    view |> element(~s(button[phx-value-tab="1"][phx-value-sec="0"])) |> render_click()

    html = view |> element(~s(button[phx-value-sec="0/1"][phx-value-key="spent"])) |> render_click()
    assert :binary.match(html, "low") |> elem(0) < :binary.match(html, "mid") |> elem(0)
    assert :binary.match(html, "mid") |> elem(0) < :binary.match(html, "high") |> elem(0)
    assert html =~ "\u2191"
  end

  test "a _cid row inside a tab table opens the shared inspector", %{conn: conn} do
    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "tab-click",
          "label" => "TabClick",
          "sections" => [
            %{
              "type" => "tabs",
              "tabs" => [
                %{
                  "label" => "Users",
                  "section" => %{
                    "type" => "table",
                    "title" => "Users",
                    "columns" => [%{"key" => "user", "label" => "user"}],
                    "rows" => [%{"user" => "@alberto", "_cid" => "tg:1:0"}]
                  }
                }
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/tab-click")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    refute html =~ "_cid"
    html = view |> element(~s(tr[phx-value-session_id="tg:1:0"])) |> render_click()
    assert html =~ "Conversation"
  end

  test "tabs are capped and malformed tabs are ignored", %{conn: conn} do
    tabs =
      Enum.map(1..8, fn n ->
        %{
          "label" => "T#{n}",
          "section" => %{"type" => "text", "title" => "S#{n}", "body" => "b"}
        }
      end) ++ ["not-a-map"]

    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "tab-cap",
          "label" => "TabCap",
          "sections" => [%{"type" => "tabs", "tabs" => tabs}]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/tab-cap")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    assert html =~ "T6"
    refute html =~ "T7"
  end

  test "tab selector uses the Usage-page join/btn style, right of the section title", %{
    conn: conn
  } do
    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "tab-style",
          "label" => "TabStyle",
          "sections" => [
            %{
              "type" => "tabs",
              "title" => "Users",
              "tabs" => [
                %{"label" => "Today", "section" => %{"type" => "text", "body" => "a"}},
                %{"label" => "All-time", "section" => %{"type" => "text", "body" => "b"}}
              ]
            }
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/tab-style")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    # same control family AND placement as the Usage range selector: joined
    # btn-xs buttons hoisted into the page header (top right), exactly one group
    assert html =~ "ext-page-selector"
    assert length(String.split(html, "join-item")) == 3
    assert html =~ "btn-xs"
    assert view |> element(~s(button[phx-value-tab="0"].btn-primary)) |> has_element?()
    refute view |> element(~s(button[phx-value-tab="1"].btn-primary)) |> has_element?()

    view |> element(~s(button[phx-value-tab="1"][phx-value-sec="0"])) |> render_click()
    assert view |> element(~s(button[phx-value-tab="1"].btn-primary)) |> has_element?()
  end

  test "span=half sections sit side by side in the section grid", %{conn: conn} do
    half = fn title ->
      %{
        "type" => "metrics",
        "title" => title,
        "span" => "half",
        "items" => [%{"label" => "X", "value" => 1}]
      }
    end

    snap =
      put_in(@snap, ["extensions", "dashboard_pages"], [
        %{
          "id" => "half-grid",
          "label" => "HalfGrid",
          "sections" => [
            half.("Today"),
            half.("All-time"),
            %{"type" => "text", "title" => "Full", "body" => "spans both columns"}
          ]
        }
      ])

    {:ok, view, _} = live(conn, "/extensions/half-grid")
    Phoenix.PubSub.broadcast(SubzeroSwarmDashboard.PubSub, "feed", {:snapshot, snap})
    html = render(view)

    # two half sections + one default full section
    assert length(String.split(html, "ext-span-half")) == 3
    assert html =~ "ext-span-full"
  end

  describe "ExtensionPages.extract_row_targets/3 (privacy seam)" do
    test "privacy resolves targets to opaque tokens and strips the raw cid" do
      page = %{
        "id" => "p",
        "sections" => [
          %{
            "type" => "table",
            "rows" => [%{"user" => "x", "_cid" => "tg:9:0"}, %{"user" => "y", "_cid" => "tg:unknown:0"}]
          }
        ]
      }

      lookup = %{"inspect:0" => "tg:9:0"}
      {clean, targets} = ExtensionPages.extract_row_targets(page, true, lookup)

      assert targets == %{{0, 0} => "inspect:0"}
      [%{"rows" => rows}] = clean["sections"]
      refute Enum.any?(rows, &Map.has_key?(&1, "_cid"))
    end

    test "clear mode passes the cid through as the target" do
      page = %{
        "id" => "p",
        "sections" => [%{"type" => "table", "rows" => [%{"user" => "x", "_cid" => "tg:9:0"}]}]
      }

      assert {_clean, %{{0, 0} => "tg:9:0"}} = ExtensionPages.extract_row_targets(page, false, %{})
    end
  end

  defp v2_usage do
    %{
      "schema_version" => 2,
      "detail_level" => "full",
      "totals" => %{
        "requests" => 1240,
        "errors" => 0,
        "tokens_in" => 1_000_000,
        "tokens_out" => 2_100_000,
        "tokens_total" => 3_100_000,
        "latency_ms_avg" => 420.0,
        "latency_ms_max" => 980.0,
        "error_rate" => 0.0,
        "last_seen" => System.os_time(:second) - 120
      },
      "by_served_model" => %{
        "gpt-5.5" => %{
          "requests" => 1240,
          "tokens_total" => 3_100_000,
          "error_rate" => 0.0,
          "latency_ms_avg" => 420.0,
          "latency_ms_max" => 980.0
        }
      },
      "by_provider" => %{"openai" => %{"requests" => 1240, "tokens_total" => 3_100_000}},
      "by_route" => %{"profile:medium" => %{"requests" => 1240, "tokens_total" => 3_100_000}},
      "by_model_family" => %{
        "gpt-5.5-codex" => %{"requests" => 1240, "tokens_total" => 3_100_000}
      },
      "consumer_settings" => %{
        "status" => "active",
        "allowed_routes" => [],
        "effective_per_min" => 600,
        "burst" => 60
      },
      "key" => %{"sha256_prefix" => "ab12cd34", "status" => "active"},
      "health_summary" => %{
        "state" => "healthy",
        "success_rate" => 1.0,
        "success_count" => 1240,
        "request_count" => 1240,
        "status_counts" => %{"200" => 1240},
        "route_failures" => 0
      },
      "route_health" => [
        %{"route" => "profile:medium", "state" => "healthy", "served_model_id" => "gpt-5.5"}
      ],
      "recent" => [
        %{
          "ts" => System.os_time(:second) - 60,
          "status" => 200,
          "served_model_id" => "gpt-5.5",
          "path" => "/v1/chat/completions",
          "latency_ms" => 420.0,
          "tokens_total" => 2537
        }
      ],
      "security" => %{"sanitized" => true, "raw_api_key_exposed" => false}
    }
  end

  test "usage renders schema v2 detail (totals, breakdowns, health, key, recent)", %{conn: conn} do
    payload = v2_usage()
    stub(SwarmClientMock, :dashboard, fn _ -> {:ok, @snap} end)
    stub(RouterClientMock, :usage, fn _ -> {:ok, payload} end)

    {:ok, view, _} = live(conn, "/usage")
    html = render(view)

    assert html =~ "Requests"
    # tokens formatted with thousands separators
    assert html =~ "3,100,000"
    # all four breakdown tables + a served-model row
    assert html =~ "By served model"
    assert html =~ "By provider"
    assert html =~ "By route"
    assert html =~ "By model family"
    assert html =~ "gpt-5.5"
    # health + key metadata + recent
    assert html =~ "healthy"
    assert html =~ "ab12cd34"
    assert html =~ "Recent requests"
    assert html =~ "schema v2"
  end

  test "usage range buttons re-query the router with a since bound", %{conn: conn} do
    test_pid = self()

    stub(RouterClientMock, :usage, fn opts ->
      send(test_pid, {:usage_opts, opts})
      {:ok, v2_usage()}
    end)

    {:ok, view, _} = live(conn, "/usage")
    # initial load uses the default "all" window → no since bound
    assert_receive {:usage_opts, opts_all}
    refute Map.has_key?(opts_all, :since)

    view |> element("button[phx-value-window='1h']") |> render_click()
    assert_receive {:usage_opts, %{since: since}}
    assert is_integer(since)
  end

  test "logs page mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/logs")
    assert html =~ "Logs"
  end

  describe "activity classification (CoreComponents.classify_activity/1)" do
    alias SubzeroSwarmDashboardWeb.CoreComponents

    test "an orchestrator-relayed user message is the user, prefix stripped" do
      assert %{kind: :user, text: "what campaigns"} =
               CoreComponents.classify_activity(%{
                 "role" => "user",
                 "content" => "[From orchestrator] what campaigns",
                 "timestamp" => "t"
               })
    end

    test "an inter-object [From policy] message is noise, labeled by source" do
      row =
        CoreComponents.classify_activity(%{
          "role" => "user",
          "content" => ~s([From policy] {"campaigns":[]})
        })

      assert row.kind == :noise
      assert row.label == "policy →"
    end

    test "a tool shell call is noise" do
      assert %{kind: :noise} =
               CoreComponents.classify_activity(%{
                 "role" => "tool",
                 "content" => ~s(shell: swarm-msg send policy '{"action":"campaigns"}')
               })
    end

    test "an exit result is noise" do
      assert %{kind: :noise} =
               CoreComponents.classify_activity(%{"role" => "res", "content" => "[exit:0] "})
    end

    test "a natural-language assistant turn is chat" do
      assert %{kind: :assistant, text: "Sent! Here's the full list"} =
               CoreComponents.classify_activity(%{
                 "role" => "asst",
                 "content" => "Sent! Here's the full list"
               })
    end

    test "an assistant tool-call emitted as text is flagged not-delivered, not shown as a reply" do
      blob =
        ~s({"cmd": "cat > /workspace/reply.json <<JSON\\n{\\"action\\":\\"reply\\",\\"text\\":\\"Yo welcome\\"}\\nJSON\\nswarm-msg send sender -f /workspace/reply.json"})

      # Previously this masked as a clean :assistant reply; now it must surface as
      # an un-executed tool call (the reply was never actually sent).
      assert %{kind: :tool_intent, text: "Yo welcome"} =
               CoreComponents.classify_activity(%{"role" => "asst", "content" => blob})
    end

    test "a <tool_call>-wrapped assistant turn is flagged not-delivered" do
      assert %{kind: :tool_intent} =
               CoreComponents.classify_activity(%{
                 "role" => "assistant",
                 "content" => ~s(<tool_call>\n{"cmd": "echo hi"}\n</tool_call>)
               })
    end

    test "an executed reply (shell tool actually ran swarm-msg send) shows as sent" do
      tool =
        ~s(shell: cat > /workspace/reply.json <<JSON\n{"action":"reply","text":"Hello there"}\nJSON\nswarm-msg send sender -f /workspace/reply.json)

      assert %{kind: :sent, text: "Hello there"} =
               CoreComponents.classify_activity(%{"role" => "tool", "content" => tool})
    end
  end

  test "logs: selecting a session loads its raw slot output", %{conn: conn} do
    stub(SwarmClientMock, :session_logs, fn _swarm, "tg:1:0" ->
      {:ok,
       %{
         "source" => "slot",
         "logs" => [%{"timestamp" => "t1", "role" => "user", "content" => "hello there"}]
       }}
    end)

    {:ok, view, _} = live(conn, "/logs")
    push_snap(view)
    view |> element("form[phx-change='select']") |> render_change(%{"session_id" => "tg:1:0"})
    html = render(view)
    assert html =~ "hello there"
    assert html =~ "slot"
  end
end
