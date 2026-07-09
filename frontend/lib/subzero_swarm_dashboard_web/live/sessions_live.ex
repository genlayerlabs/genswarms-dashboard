defmodule SubzeroSwarmDashboardWeb.SessionsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  # Classifier + thresholds live in ReplyHealth — shared with Overview's
  # attention tile so the two pages can never disagree about "unanswered".
  alias SubzeroSwarmDashboardWeb.ReplyHealth
  alias SubzeroSwarmDashboardWeb.DashHooks

  # DOM cap: with a 750+ roster every row re-diffs on each 3s snapshot poll;
  # the long tail hides behind one "show all" row instead.
  @page_size 50

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Sessions", q: "", filter: "all", expanded: false)}

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  @impl true
  def handle_event("filter", %{"f" => f}, socket),
    do: {:noreply, assign(socket, filter: f, expanded: false)}

  @impl true
  def handle_event("expand", _params, socket),
    do: {:noreply, assign(socket, expanded: true)}

  @impl true
  def handle_event("collapse", _params, socket),
    do: {:noreply, assign(socket, expanded: false)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])
    sessions = filter(assigns[:snapshot], assigns.q)
    now = System.os_time(:second)
    deliveries = ReplyHealth.deliveries(assigns[:snapshot])
    suppressed = ReplyHealth.suppressed_by_cid(assigns.story)

    statuses =
      Map.new(sessions, &{&1["session_id"], ReplyHealth.status(&1, deliveries, suppressed, now)})

    sessions = sort_by_attention(sessions, statuses)

    # Chip facets are counted over the search scope, so search + chips agree.
    chip_counts = chip_counts(sessions, statuses)

    # Search overrides the chip filter AND the DOM cap: a query must show
    # every match, whatever facet was active.
    visible =
      if assigns.q == "",
        do: apply_chip_filter(sessions, statuses, assigns.filter),
        else: sessions

    {shown, hidden_count} =
      if assigns.expanded or assigns.q != "" do
        {visible, 0}
      else
        {Enum.take(visible, @page_size), max(length(visible) - @page_size, 0)}
      end

    assigns =
      assign(assigns,
        inspect_lookup: inspect_lookup,
        sessions: sessions,
        shown: shown,
        shown_rows: session_rows(shown, privacy?, inspect_lookup, statuses, now),
        hidden_count: hidden_count,
        statuses: statuses,
        chip_counts: chip_counts,
        live_count: chip_counts["live"],
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
          <form phx-change="search" class="w-full max-w-sm">
            <label class="input input-bordered input-sm flex items-center gap-2 w-full">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
              <input
                type="text"
                name="q"
                value={@q}
                placeholder="search @handle · name · session · chat id"
                class="grow bg-transparent outline-none"
                autocomplete="off"
              />
            </label>
          </form>
          <div :if={@snapshot} class="flex flex-wrap gap-1.5 items-center ml-auto">
            <.facet_chip
              :for={{key, label, title} <- facets()}
              key={key}
              label={label}
              title={title}
              count={@chip_counts[key]}
              active={@filter == key}
            />
          </div>
        </div>

        <.panel
          :if={@snapshot}
          title="Sessions"
          body_class={if(@sessions == [], do: "p-4", else: "overflow-x-auto")}
        >
          <:meta>
            <span class="font-mono tnum">{length(@sessions)} total</span>
            <span class="font-mono tnum text-[var(--signal)]">{@live_count} live</span>
          </:meta>
          <%= if @sessions == [] do %>
            <.empty_state
              icon="hero-magnifying-glass"
              msg={"No sessions#{if(@q != "", do: " match \"#{@q}\"", else: "")}."}
            />
          <% else %>
            <table class="table">
              <thead>
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
                <tr :if={@hidden_count > 0}>
                  <td colspan="6" class="p-0">
                    <button
                      type="button"
                      phx-click="expand"
                      class="w-full py-2 text-xs opacity-60 hover:opacity-100 text-center"
                    >
                      — show {@hidden_count} more —
                    </button>
                  </td>
                </tr>
                <tr :if={@expanded and @q == ""}>
                  <td colspan="6" class="p-0">
                    <button
                      type="button"
                      phx-click="collapse"
                      class="w-full py-2 text-xs opacity-60 hover:opacity-100 text-center"
                    >
                      — show fewer —
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
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

  defp filter(nil, _q), do: []

  defp filter(snap, q) do
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
      {"live", "live", "currently leased to an agent slot"},
      {"unanswered", "⚠ unanswered", "received a message but got no reply (fresh — under 48h)"},
      {"suppressed", "🤫 suppressed",
       "replies withheld by the sender's spam window — policy, not a failure"},
      {"stale", "stale", "unanswered for over 48h — aged out of the alarm"},
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
       when f in ["unanswered", "suppressed", "stale", "idle", "answered", "pending"],
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
  def reply_status(session, deliveries, now),
    do: ReplyHealth.status(session, deliveries, %{}, now)

  def reply_status(session, deliveries, suppressed, now),
    do: ReplyHealth.status(session, deliveries, suppressed, now)

  # Attention-first: the row that hurts most goes on top. Unanswered sort oldest
  # first (longest-waiting user at the very top); every other bucket sorts most
  # recent first. Stale (aged-out unanswered) sits below answered — visible
  # history, not an alarm. Public for unit tests.
  @attention_rank %{unanswered: 0, pending: 1, suppressed: 2, answered: 3, stale: 4, idle: 5}

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
