defmodule SubzeroSwarmDashboardWeb.EventsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.SwarmClient

  @refresh_ms 5_000
  # the stream mirrors the story ring cap; the pause buffer is bounded the same
  @stream_max 500
  @pending_max 500
  # State.summary/1 ships the newest 50 story rows per tick — the seen-set only
  # needs to cover that tail to diff fresh rows out of the next tick
  @summary_tail 50

  # event registry v1 + the synthetic/derived kinds the fold can emit (spec §2/§5.3)
  @kinds ~w(request_open routed spawn_start teardown inbox_full ask browse_dispatch
            browse_done progress_sent reply_sent reply_failed compaction inbox_dropped
            stalled feed_gap feed_restart)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Events",
        # engine-raw view (the existing LogStore table), demoted behind the toggle
        events: :loading,
        # server-side filters
        level: "",
        category: "",
        agent: "",
        minutes: "",
        # client-side text search over the message
        contains: "",
        timer: nil,
        # story view: pause buffers incoming rows instead of yanking the reader
        paused: false,
        pending: [],
        pending_count: 0,
        seen: MapSet.new()
      )
      |> stream_configure(:story_rows, dom_id: &row_dom_id/1)

    if connected?(socket), do: send(self(), :load)
    {:ok, socket}
  end

  # Story filters live in the URL (spec §5.6): /events?cid=…&issues=1 is shareable
  # and is the deep-link target for every issue row on Overview/Sessions.
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(
        view: if(params["view"] == "raw", do: "raw", else: "story"),
        kind: params["kind"] || "",
        cid: params["cid"] || "",
        agent_f: params["agent"] || "",
        issues: params["issues"] in ["1", "true"]
      )
      |> reset_story()

    {:noreply, socket}
  end

  @impl true
  def handle_event("story_filter", params, socket) do
    # the @handle dropdown is sugar over the cid filter (handle → session_id);
    # _target says which control changed so the free cid input isn't clobbered
    cid =
      if params["_target"] == ["user"],
        do: params["user"] || "",
        else: params["cid"] || ""

    {:noreply,
     push_patch(socket,
       to:
         story_path(socket.assigns,
           kind: params["kind"] || "",
           cid: cid,
           agent: params["agent"] || "",
           issues: params["issues"] == "1"
         )
     )}
  end

  def handle_event("pause", _params, socket),
    do: {:noreply, assign(socket, paused: true, pending: [], pending_count: 0)}

  def handle_event("resume", _params, socket) do
    socket =
      socket
      |> prepend_rows(socket.assigns.pending)
      |> assign(paused: false, pending: [], pending_count: 0)

    {:noreply, socket}
  end

  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(
        level: params["level"] || "",
        category: params["category"] || "",
        agent: params["agent"] || "",
        minutes: params["minutes"] || "",
        contains: params["contains"] || ""
      )
      |> assign(events: :loading)
      |> reload()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, reload(socket)}

  # Live story ticks (PubSub "events", relayed through DashHooks): diff the
  # summary's newest-first tail against what we've already seen, then prepend —
  # or buffer behind the pause pill.
  def handle_info({:story, summary}, socket) do
    {fresh, seen} = diff_new(summary[:story] || [], socket.assigns.seen)
    fresh = filter_rows(fresh, socket.assigns)
    socket = assign(socket, seen: seen)

    socket =
      cond do
        socket.assigns.view == "raw" or fresh == [] ->
          socket

        socket.assigns.paused ->
          pending = Enum.take(fresh ++ socket.assigns.pending, @pending_max)
          assign(socket, pending: pending, pending_count: length(pending))

        true ->
          prepend_rows(socket, fresh)
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── story view plumbing ──────────────────────────────────────────────────────

  # filtering a stream = refetch + reset: re-pull the full ring, re-filter, and
  # re-seed the seen-set that diffs live ticks
  defp reset_story(socket) do
    ring = story_ring()

    socket
    |> assign(seen: MapSet.new(Enum.take(ring, @summary_tail), &row_dom_id/1))
    |> assign(paused: false, pending: [], pending_count: 0)
    |> stream(:story_rows, ring |> filter_rows(socket.assigns) |> Enum.take(@stream_max),
      reset: true
    )
  end

  # the feed GenServer isn't running under test (:start_feed false) and may not
  # be up yet during boot — degrade to live ticks only
  defp story_ring do
    EventsFeed.story_ring()
  catch
    :exit, _ -> []
  end

  defp diff_new(rows, seen) do
    fresh = Enum.take_while(rows, &(not MapSet.member?(seen, row_dom_id(&1))))
    {fresh, MapSet.new(Enum.take(rows, @summary_tail), &row_dom_id/1)}
  end

  defp filter_rows(rows, a) do
    Enum.filter(rows, fn r ->
      (a.kind == "" or r.kind == a.kind) and
        (a.cid == "" or r.cid == a.cid) and
        (a.agent_f == "" or r.agent == a.agent_f) and
        (not a.issues or r.issue)
    end)
  end

  # rows arrive newest-first; inserting oldest-first at 0 lands them in order
  defp prepend_rows(socket, rows) do
    rows
    |> Enum.reverse()
    |> Enum.reduce(socket, &stream_insert(&2, :story_rows, &1, at: 0, limit: @stream_max))
  end

  # seq is nil for synthetic rows (feed_gap / feed_restart / stalled) — fall
  # back to the timestamp + a kind/cid hash (episodes can stall on the SAME tick)
  defp row_dom_id(%{seq: seq}) when is_integer(seq), do: "story-row-#{seq}"

  defp row_dom_id(row),
    do: "story-row-t#{trunc((row[:ts] || 0.0) * 1000)}-#{:erlang.phash2({row[:kind], row[:cid]})}"

  # only non-default filters appear in the URL, so deep links stay minimal
  defp story_path(a, overrides) do
    params =
      [view: a.view, kind: a.kind, cid: a.cid, agent: a.agent_f, issues: a.issues]
      |> Keyword.merge(overrides)
      |> Enum.flat_map(fn
        {:view, "story"} -> []
        {_k, ""} -> []
        {:issues, false} -> []
        {:issues, true} -> [{:issues, "1"}]
        kv -> [kv]
      end)

    ~p"/events?#{params}"
  end

  # nobody types tg:5681202:0 by hand — the dropdown maps @handle → session_id
  defp user_options(snapshot) do
    for s <- (is_map(snapshot) && snapshot["sessions"]) || [],
        h = get_in(s, ["user", "handle"]),
        is_binary(h) and h != "" do
      {"@" <> h, s["session_id"]}
    end
  end

  # ── engine-raw plumbing (unchanged) ──────────────────────────────────────────

  # Single recurring refresh: cancel any pending timer, fetch with the server-side
  # filters, reschedule exactly one.
  defp reload(socket) do
    if ref = socket.assigns[:timer], do: Process.cancel_timer(ref)
    timer = Process.send_after(self(), :load, @refresh_ms)

    assign(socket,
      events: SwarmClient.events(socket.assigns.swarm, server_opts(socket.assigns)),
      timer: timer
    )
  end

  defp server_opts(a) do
    %{limit: 200}
    |> put_if(:level, a.level)
    |> put_if(:category, a.category)
    |> put_if(:agent, a.agent)
    |> put_minutes(a.minutes)
  end

  defp put_if(opts, _k, ""), do: opts
  defp put_if(opts, k, v), do: Map.put(opts, k, v)

  defp put_minutes(opts, ""), do: opts

  defp put_minutes(opts, m) do
    case Integer.parse(m) do
      {n, _} -> Map.put(opts, :minutes, n)
      _ -> opts
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        kinds: @kinds,
        story_href: story_path(assigns, view: "story"),
        raw_href: story_path(assigns, view: "raw"),
        user_opts: user_options(assigns[:snapshot])
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:events}
      swarm={@swarm}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h1 class="text-2xl">
            Events
            <span class="text-xs opacity-50 font-sans align-middle">the live request story</span>
          </h1>
          <div id="events-view-toggle" class="join">
            <.link
              patch={@story_href}
              id="events-view-story"
              class={[
                "btn btn-sm join-item",
                if(@view == "story", do: "btn-primary", else: "btn-ghost")
              ]}
            >
              story
            </.link>
            <.link
              patch={@raw_href}
              id="events-view-raw"
              class={[
                "btn btn-sm join-item",
                if(@view == "raw", do: "btn-primary", else: "btn-ghost")
              ]}
            >
              engine raw
            </.link>
          </div>
        </div>

        <div :if={@view == "story"} id="story-view" class="space-y-3">
          <div class="flex flex-wrap gap-2 items-center text-sm">
            <form
              id="story-filter-form"
              phx-change="story_filter"
              class="flex flex-wrap gap-2 items-center"
            >
              <select name="kind" class="select select-bordered select-sm">
                <option value="" selected={@kind == ""}>all kinds</option>
                <option :for={k <- @kinds} value={k} selected={@kind == k}>{k}</option>
              </select>
              <select name="user" id="story-user-select" class="select select-bordered select-sm">
                <option value="">user…</option>
                <option :for={{label, sid} <- @user_opts} value={sid} selected={@cid == sid}>
                  {label}
                </option>
              </select>
              <input
                type="text"
                name="cid"
                value={@cid}
                placeholder="cid (deep link)"
                class="input input-bordered input-sm w-40"
              />
              <input
                type="text"
                name="agent"
                value={@agent_f}
                placeholder="agent"
                class="input input-bordered input-sm w-28"
              />
              <label class="cursor-pointer flex items-center gap-1.5">
                <input
                  type="checkbox"
                  name="issues"
                  value="1"
                  checked={@issues}
                  class="checkbox checkbox-xs"
                /> issues only
              </label>
            </form>
            <%!-- reading vs live (spec §5.6): pause buffers, resume prepends the buffer --%>
            <button
              type="button"
              id="events-pause"
              phx-click={if(@paused, do: "resume", else: "pause")}
              class={["btn btn-sm gap-1.5", if(@paused, do: "btn-warning", else: "btn-ghost")]}
            >
              <%= if @paused do %>
                ▶ live
                <span :if={@pending_count > 0} class="badge badge-sm tnum">
                  +{@pending_count} new
                </span>
              <% else %>
                ⏸ pause
              <% end %>
            </button>
          </div>

          <div
            id="story-rows"
            phx-update="stream"
            class="font-mono text-xs divide-y divide-base-300/40"
          >
            <%!-- every child of a stream container needs an id, the empty state too --%>
            <div id="story-empty" class="hidden only:block py-2 opacity-60">
              no story rows yet — waiting on the feed…
            </div>
            <div
              :for={{id, row} <- @streams.story_rows}
              id={id}
              class="flex items-baseline gap-3 py-1"
            >
              <span class="opacity-50 whitespace-nowrap">{fmt_ts(row.ts)}</span>
              <span class={["flex-1 truncate", row.issue && "text-warning"]}>{row.text}</span>
              <.link
                :if={row.cid}
                navigate={session_href(row.cid)}
                class="link link-hover opacity-60 whitespace-nowrap"
              >
                session
              </.link>
            </div>
          </div>
        </div>

        <div :if={@view == "raw"} id="raw-view" class="space-y-5">
          <form
            id="raw-filter-form"
            phx-change="filter"
            class="flex flex-wrap gap-2 items-center text-sm"
          >
            <select name="level" class="select select-bordered select-sm">
              <option value="" selected={@level == ""}>all levels</option>
              <option :for={l <- ~w(error warning info debug)} value={l} selected={@level == l}>
                {l}
              </option>
            </select>
            <select name="category" class="select select-bordered select-sm">
              <option value="" selected={@category == ""}>all categories</option>
              <option
                :for={c <- ~w(swarm agent object router system)}
                value={c}
                selected={@category == c}
              >
                {c}
              </option>
            </select>
            <input
              type="text"
              name="agent"
              value={@agent}
              placeholder="agent"
              class="input input-bordered input-sm w-28"
            />
            <select name="minutes" class="select select-bordered select-sm">
              <option value="" selected={@minutes == ""}>all time</option>
              <option
                :for={{m, lbl} <- [{"5", "5m"}, {"60", "1h"}, {"1440", "24h"}]}
                value={m}
                selected={@minutes == m}
              >
                {lbl}
              </option>
            </select>
            <input
              type="text"
              name="contains"
              value={@contains}
              placeholder="contains text"
              class="input input-bordered input-sm w-40"
            />
          </form>

          <.event_table events={@events} contains={@contains} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :events, :any, required: true
  attr :contains, :string, default: ""

  defp event_table(%{events: {:ok, events}} = assigns) do
    assigns = assign(assigns, :events, client_filter(events, assigns.contains))

    ~H"""
    <table class="table table-xs">
      <thead>
        <tr>
          <th>time</th>
          <th>level</th>
          <th>category</th>
          <th>agent</th>
          <th>message</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={e <- @events}>
          <td class="text-xs opacity-60 whitespace-nowrap">{e["timestamp"]}</td>
          <td><span class={["badge badge-xs", level_class(e["level"])]}>{e["level"]}</span></td>
          <td class="text-xs">{e["category"]}</td>
          <td class="font-mono text-xs">{e["agent"]}</td>
          <td class="text-xs">{e["message"]}</td>
        </tr>
        <tr :if={@events == []}>
          <td colspan="5" class="opacity-60">No events match.</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp event_table(%{events: :loading} = assigns) do
    ~H"""
    <div class="opacity-60">loading…</div>
    """
  end

  defp event_table(assigns) do
    ~H"""
    <div class="opacity-60">Events unavailable (is the swarm API reachable?).</div>
    """
  end

  defp client_filter(events, ""), do: events

  defp client_filter(events, q) do
    q = String.downcase(q)
    Enum.filter(events, &String.contains?(String.downcase(to_string(&1["message"])), q))
  end

  defp level_class("error"), do: "badge-error"
  defp level_class("warning"), do: "badge-warning"
  defp level_class(_), do: "badge-ghost"

  # cids carry colons (tg:<chat>:<thread>) — encode like SessionsLive does
  defp session_href(cid), do: ~p"/sessions/#{Base.url_encode64(cid, padding: false)}"

  defp fmt_ts(ts) when is_number(ts),
    do: ts |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%H:%M:%S")

  defp fmt_ts(_ts), do: "—"
end
