defmodule SubzeroSwarmDashboardWeb.SessionsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  # Classifier + thresholds live in ReplyHealth — shared with Overview's
  # attention tile so the two pages can never disagree about "unanswered".
  alias SubzeroSwarmDashboardWeb.ReplyHealth
  alias SubzeroSwarmDashboardWeb.DashHooks
  alias SubzeroSwarmDashboardWeb.Pagination

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Sessions", q: "", filter: "all", page: 1)
     |> DashHooks.refresh_snapshot()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q),
    do: {:noreply, socket |> assign(q: q, page: 1) |> DashHooks.refresh_snapshot()}

  @impl true
  def handle_event("filter", %{"f" => f}, socket),
    do: {:noreply, socket |> assign(filter: f, page: 1) |> DashHooks.refresh_snapshot()}

  @impl true
  def handle_event("sessions_page", %{"page" => page}, socket),
    do: {:noreply, socket |> assign(page: Pagination.page(page)) |> DashHooks.refresh_snapshot()}

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Filter and page a full shared snapshot before copying it to a viewer."
  def prepare_snapshot(nil, _assigns), do: nil
  def prepare_snapshot(%{"_sessions_page" => _} = snapshot, _assigns), do: snapshot

  def prepare_snapshot(snapshot, assigns) do
    sessions = matching_sessions(snapshot, assigns[:q] || "")
    now = System.os_time(:second)
    replies = ReplyHealth.replies(snapshot)
    suppressed = ReplyHealth.suppressed_by_cid(assigns[:story])

    statuses =
      Map.new(sessions, &{&1["session_id"], ReplyHealth.status(&1, replies, suppressed, now)})

    visible =
      sessions
      |> apply_chip_filter(statuses, assigns[:filter] || "all")
      |> sort_by_attention(statuses)

    {shown, pagination} = Pagination.slice(visible, assigns[:page])

    metadata =
      Map.merge(pagination, %{
        total: length(snapshot["sessions"] || []),
        search_total: length(sessions),
        filtered_total: pagination.total,
        chip_counts: chip_counts(sessions, statuses),
        statuses: Map.take(statuses, Enum.map(shown, & &1["session_id"]))
      })

    snapshot |> Map.put("sessions", shown) |> Map.put("_sessions_page", metadata)
  end

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])
    projected = prepare_snapshot(assigns[:snapshot] || %{}, assigns)
    sessions = projected["sessions"]
    metadata = projected["_sessions_page"]
    now = System.os_time(:second)

    assigns =
      assign(assigns,
        inspect_lookup: inspect_lookup,
        sessions: sessions,
        sessions_available: (assigns[:snapshot] || %{})["sessions_available"] != false,
        shown_rows: session_rows(sessions, privacy?, inspect_lookup, metadata.statuses, now),
        total: metadata.total,
        pagination: Map.put(metadata, :total, metadata.filtered_total),
        statuses: metadata.statuses,
        chip_counts: metadata.chip_counts,
        live_count: metadata.chip_counts["live"],
        issues_by_cid: story_issues(assigns.story),
        modes_by_cid: modes_by_cid(assigns[:snapshot]),
        audience: audience(assigns[:snapshot]),
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:sessions}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5">
        <h1 class="text-2xl">Sessions</h1>

        <%!-- one toolbar: search left, clickable status facets right --%>
        <div class="flex flex-wrap gap-2 items-center rounded-box border border-base-300 bg-base-200/60 px-3 py-2.5 text-sm">
          <form id="sessions-search" phx-change="search" class="w-full max-w-sm">
            <label class="input input-bordered input-sm flex items-center gap-2 w-full">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
              <input
                type="text"
                name="q"
                value={@q}
                placeholder="search @handle · name · session · chat id"
                class="grow bg-transparent outline-none"
                autocomplete="off"
                phx-debounce="250"
              />
            </label>
          </form>
          <div :if={@snapshot} class="flex flex-wrap gap-1.5 items-center ml-auto">
            <.facet_chip
              :for={{key, label, title} <- facets()}
              key={key}
              label={if key == "all" and not @sessions_available, do: "known", else: label}
              title={if key == "all" and not @sessions_available, do: "known sessions", else: title}
              count={@chip_counts[key]}
              active={@filter == key}
            />
          </div>
        </div>

        <.panel
          :if={@snapshot}
          title="Sessions"
          body_class="px-4"
        >
          <:meta>
            <span id="sessions-total" class="font-mono tnum">
              <%= if @sessions_available do %>
                {@total} total
              <% else %>
                total unavailable · {@total} known
              <% end %>
            </span>
            <span class="font-mono tnum text-[var(--signal)]">{@live_count} live</span>
          </:meta>
          <%= if @sessions == [] do %>
            <.empty_state
              icon="hero-magnifying-glass"
              msg={
                if not @sessions_available,
                  do: "Stored sessions unavailable.",
                  else: "No sessions#{if(@q != "", do: " match \"#{@q}\"", else: "")}."
              }
            />
          <% else %>
            <div id="sessions-scroll" class="max-h-[65vh] overflow-auto scroll-thin">
              <table id="sessions-table" class="table">
                <thead class="sticky top-0 z-10 bg-base-200">
                  <tr class="text-xs uppercase tracking-wide">
                    <th>User</th>
                    <th>State</th>
                    <th>Health</th>
                    <th>Mode</th>
                    <th>Last seen</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @shown_rows}
                    class="row-press"
                    phx-click="inspect"
                    phx-keydown="inspect"
                    phx-key="Enter"
                    phx-value-session_id={row.inspect_value}
                    tabindex="0"
                  >
                    <td>
                      <div class="flex items-center gap-2 min-w-0">
                        <%= if @privacy do %>
                          <.identity_avatar
                            user={row.session["user"]}
                            session_id={row.sid}
                            label={row.session["label"]}
                            privacy={@privacy}
                          />
                          <span class="font-mono text-sm">•••</span>
                        <% else %>
                          <.identity
                            user={row.session["user"]}
                            session_id={row.sid}
                            label={row.session["label"]}
                          />
                          <span
                            :if={topic_of(row.session)}
                            class="badge badge-outline badge-xs font-mono shrink-0"
                          >
                            topic {topic_of(row.session)}
                          </span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="flex items-center gap-2 whitespace-nowrap">
                        <.live_dot state={row.session["state"]} label />
                        <span
                          :if={row.session["agent"]}
                          class="font-mono text-xs opacity-70"
                        >
                          {row.session["agent"]}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="flex items-center gap-1.5 whitespace-nowrap">
                        <.reply_badge status={@statuses[row.sid]} waiting={row.waiting} />
                        <.issue_badge
                          sid={row.sid}
                          issues={@issues_by_cid[row.sid] || []}
                          privacy={@privacy}
                        />
                      </div>
                    </td>
                    <td><.mode_badge mode={@modes_by_cid[row.sid]} /></td>
                    <td class="text-sm opacity-70 tnum whitespace-nowrap">
                      {relative_time(row.session["last_activity"])}
                    </td>
                    <td class="text-right">
                      <%= if @privacy do %>
                        <button
                          type="button"
                          phx-click="inspect"
                          phx-value-session_id={row.inspect_value}
                          class="btn btn-ghost btn-xs btn-circle"
                          onclick="event.stopPropagation()"
                          title="Inspect session"
                        >
                          <.icon name="hero-arrow-up-right" class="size-4 opacity-60" />
                        </button>
                      <% else %>
                        <.link
                          navigate={~p"/sessions/#{Base.url_encode64(row.sid, padding: false)}"}
                          class="btn btn-ghost btn-xs btn-circle"
                          onclick="event.stopPropagation()"
                          title="Open full session"
                        >
                          <.icon name="hero-arrow-up-right" class="size-4 opacity-60" />
                        </.link>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
          <Pagination.pager id="sessions-pager" event="sessions_page" pagination={@pagination} />
        </.panel>

        <.panel :if={@audience} id="audience-footer" title="Audience">
          <div class="grid grid-cols-2 md:grid-cols-4 xl:grid-cols-6 gap-x-4 gap-y-3">
            <.metric
              :for={{k, v} <- @audience}
              label={String.replace(to_string(k), "_", " ")}
              value={audience_value(v)}
            />
          </div>
        </.panel>

        <.empty_state :if={is_nil(@snapshot)} msg="Waiting for the first snapshot…" />
      </div>
    </Layouts.app>
    """
  end

  # A forum group's sub-thread, straight from the adapter's transport_ref DATA
  # (never parsed out of the cid). Only meaningful for group chats; the
  # transport's "default thread" sentinels (nil/""/"0") render nothing.
  defp topic_of(%{
         "metadata" => %{"chat_type" => "group"},
         "transport_ref" => %{"thread_id" => t}
       })
       when t not in [nil, "", "0"],
       do: t

  defp topic_of(_session), do: nil

  @doc "Search the complete roster by displayed identity and transport references."
  def matching_sessions(nil, _q), do: []

  def matching_sessions(snap, q) do
    sessions = snap["sessions"] || []
    q = String.downcase(q || "")

    if q == "" do
      sessions
    else
      Enum.filter(sessions, &session_matches?(&1, q))
    end
  end

  defp session_matches?(s, q) do
    haystack =
      [
        s["session_id"],
        s["label"],
        get_in(s, ["user", "handle"]),
        get_in(s, ["user", "name"]),
        s["agent"]
      ]
      |> Enum.concat(Map.values(s["transport_ref"] || %{}))
      |> Enum.map(&String.downcase(to_string(&1)))

    Enum.any?(haystack, &String.contains?(&1, q))
  end

  defp session_rows(sessions, privacy?, inspect_lookup, statuses, now) do
    Enum.map(sessions, fn s ->
      sid = s["session_id"]

      %{
        session: s,
        sid: sid,
        inspect_value: DashHooks.inspect_value(inspect_lookup, privacy? == true, sid),
        waiting: waiting_label(statuses[sid], s["last_activity"], now)
      }
    end)
  end

  # How long the user has been waiting — rendered inside the no-reply badge,
  # because on an oldest-first unanswered sort the operative number is the wait,
  # not a generic "last seen".
  defp waiting_label(st, last_activity, now) when st in [:unanswered, :stale] do
    case to_unix(last_activity) do
      nil -> nil
      t -> ago_compact(max(now - t, 0))
    end
  end

  defp waiting_label(_st, _last_activity, _now), do: nil

  defp ago_compact(s) when s < 3600, do: "#{div(s, 60)}m"
  defp ago_compact(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp ago_compact(s), do: "#{div(s, 86_400)}d"

  # ── status facets (chips) ────────────────────────────────────────────────────
  # The old toolbar badges were inert labels; each facet is one click away from
  # the rows it counts. Keys double as the filter value.
  defp facets do
    [
      {"all", "all", "every session"},
      {"live", "live", "leased to an agent present in the engine"},
      {"unanswered", "⚠ unanswered", "received a message but got no reply (fresh — under 48h)"},
      {"suppressed", "🤫 suppressed",
       "replies withheld by the sender's spam window — policy, not a failure"},
      {"stale", "stale", "unanswered for over 48h — aged out of the alarm"},
      {"unavailable", "unavailable", "reply evidence unavailable"},
      {"idle", "idle", "no activity recorded"}
    ]
  end

  defp chip_counts(sessions, statuses) do
    by_status =
      Enum.reduce(sessions, %{}, fn s, acc ->
        st = Atom.to_string(statuses[s["session_id"]] || :idle)
        Map.update(acc, st, 1, &(&1 + 1))
      end)

    Map.merge(by_status, %{
      "all" => length(sessions),
      "live" => Enum.count(sessions, &(&1["state"] == "active"))
    })
  end

  defp apply_chip_filter(sessions, _statuses, "all"), do: sessions

  defp apply_chip_filter(sessions, _statuses, "live"),
    do: Enum.filter(sessions, &(&1["state"] == "active"))

  defp apply_chip_filter(sessions, statuses, f)
       when f in [
              "unanswered",
              "suppressed",
              "stale",
              "idle",
              "answered",
              "pending",
              "unavailable"
            ],
       do:
         Enum.filter(
           sessions,
           &(Atom.to_string(statuses[&1["session_id"]] || :idle) == f)
         )

  defp apply_chip_filter(sessions, _statuses, _unknown), do: sessions

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :count, :any, default: nil
  attr :active, :boolean, default: false

  # Facets with nothing to show stay out of the toolbar ("all" always renders,
  # and an ACTIVE facet stays visible even at zero so it can be un-clicked).
  defp facet_chip(%{key: key, count: count, active: false} = assigns)
       when key != "all" and (is_nil(count) or count == 0) do
    ~H""
  end

  defp facet_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-f={@key}
      title={@title}
      class={[
        "badge badge-sm gap-1 cursor-pointer transition-opacity",
        @active && "badge-neutral",
        !@active && "badge-ghost opacity-70 hover:opacity-100",
        @key == "unanswered" && !@active && "badge-warning opacity-100"
      ]}
    >
      {@label} <span class="font-mono tnum">{@count || 0}</span>
    </button>
    """
  end

  # The old Consumers panel was 139 raw cids duplicating this table — its one
  # useful fact (the push-mode tier + opt-out) now lives on each session row.
  defp modes_by_cid(nil), do: %{}

  defp modes_by_cid(snap) do
    for c <- get_in(snap, ["extensions", "consumers", "items"]) || [],
        is_binary(c["session_id"]),
        into: %{},
        do: {c["session_id"], %{mode: c["mode"], opt_out: c["opt_out"] == true}}
  end

  attr :mode, :any, default: nil

  defp mode_badge(%{mode: nil} = assigns) do
    ~H"""
    <span class="opacity-40 text-xs">—</span>
    """
  end

  defp mode_badge(assigns) do
    ~H"""
    <span class="text-xs opacity-70">{@mode.mode}</span>
    <span :if={@mode.opt_out} class="badge badge-ghost badge-xs" title="opted out of proactive pushes">
      opted out
    </span>
    """
  end

  # ── per-row issue badges (spec §5.6 Sessions) ───────────────────────────────
  # The @story issues tail is already 24h-windowed by the reducer's tick — just
  # group it so each row can match by cid == session_id.
  defp story_issues(nil), do: %{}
  defp story_issues(story), do: Enum.group_by(story[:issues] || [], & &1[:cid])

  # ── audience footer (spec §6.3) ─────────────────────────────────────────────
  # Host-defined block: render exactly the fields present, sorted for a stable
  # layout; omit the card entirely when the host publishes nothing.
  defp audience(nil), do: nil

  defp audience(snap) do
    case get_in(snap, ["extensions", "audience"]) do
      a when is_map(a) and map_size(a) > 0 -> Enum.sort_by(a, &elem(&1, 0))
      _ -> nil
    end
  end

  defp audience_value(v) when is_number(v) or is_binary(v), do: v
  defp audience_value(v), do: inspect(v)

  @doc "Delegates to ReplyHealth (the shared classifier). Public for unit tests."
  def reply_status(session, replies, now),
    do: ReplyHealth.status(session, replies, %{}, now)

  def reply_status(session, replies, suppressed, now),
    do: ReplyHealth.status(session, replies, suppressed, now)

  # Attention-first: the row that hurts most goes on top. Unanswered sort oldest
  # first (longest-waiting user at the very top); every other bucket sorts most
  # recent first. Stale (aged-out unanswered) sits below answered — visible
  # history, not an alarm. Public for unit tests.
  @attention_rank %{
    unanswered: 0,
    pending: 1,
    suppressed: 2,
    answered: 3,
    stale: 4,
    unavailable: 5,
    idle: 6
  }

  def sort_by_attention(sessions, statuses) do
    Enum.sort_by(sessions, fn s ->
      st = statuses[s["session_id"]] || :idle
      la = to_unix(s["last_activity"]) || 0
      {@attention_rank[st], if(st == :unanswered, do: la, else: -la)}
    end)
  end

  defp to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp to_unix(_), do: nil

  attr :status, :atom, required: true
  attr :waiting, :string, default: nil

  defp reply_badge(assigns) do
    ~H"""
    <span
      :if={@status == :answered}
      class="badge badge-success badge-xs"
      title="replied to the last message"
    >
      answered
    </span>
    <span
      :if={@status == :pending}
      class="badge badge-ghost badge-xs"
      title="received — reply in flight"
    >
      replying…
    </span>
    <span
      :if={@status == :unanswered}
      class="badge badge-warning badge-xs whitespace-nowrap"
      title="received a message but never replied"
    >
      ⚠ no reply{if @waiting, do: " · #{@waiting}"}
    </span>
    <span
      :if={@status == :suppressed}
      class="badge badge-ghost badge-xs"
      title="reply withheld by the sender's spam window — policy, not a failure"
    >
      🤫 suppressed
    </span>
    <span
      :if={@status == :stale}
      class="badge badge-ghost badge-xs opacity-60 whitespace-nowrap"
      title="unanswered for over 48h — aged out of the alarm"
    >
      no reply{if @waiting, do: " · #{@waiting}"}
    </span>
    <span
      :if={@status == :unavailable}
      class="badge badge-ghost badge-xs"
      title="successful reply evidence unavailable"
    >
      unavailable
    </span>
    <span :if={@status == :idle} class="opacity-40 text-xs">—</span>
    """
  end

  attr :sid, :string, required: true
  attr :issues, :list, default: []
  attr :privacy, :boolean, default: false

  # Event-derived trouble for this conversation (delivery failures, inbox_full,
  # stalled, …) within the issues window. The id is url-safe-base64 of the cid —
  # same encoding the row's deep-link uses — because cids contain colons. Deep-links
  # to the cid-filtered issues-only Events story view (spec §5.6), like Overview.
  defp issue_badge(%{issues: [_ | _], privacy: true} = assigns) do
    ~H"""
    <span class="badge badge-error badge-xs gap-1 whitespace-nowrap">
      ⚠ {length(@issues)}
    </span>
    """
  end

  defp issue_badge(%{issues: [_ | _]} = assigns) do
    ~H"""
    <.link
      id={"session-issues-#{Base.url_encode64(@sid, padding: false)}"}
      navigate={~p"/events?#{[cid: @sid, issues: 1]}"}
      class="badge badge-error badge-xs gap-1 whitespace-nowrap"
      title={Enum.map_join(@issues, "\n", & &1[:text])}
      onclick="event.stopPropagation()"
    >
      ⚠ {length(@issues)}
    </.link>
    """
  end

  # No issues ⇒ nothing: the badge shares the Health cell with the reply badge
  # now, so an em-dash here would just be noise next to a real status.
  defp issue_badge(assigns) do
    ~H""
  end
end
