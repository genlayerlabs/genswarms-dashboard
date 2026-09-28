defmodule SubzeroSwarmDashboardWeb.DashHooks do
  @moduledoc """
  `on_mount` hook shared by every dashboard LiveView. Subscribes to the `SwarmFeed`
  PubSub and centralizes the feed messages (`{:snapshot}`/`{:disconnected}`/
  `{:warning}`) via an attached `handle_info` hook, so pages only render `@snapshot`.
  Live `{:event, ...}` messages fall through (`:cont`) for pages that want them.

  Same pattern for the display-event feed (`EventsFeed`, topic `"events"`):
  `{:story, summary}` is centralized into `@story`; raw `{:display_event, ...}`
  falls through for pages that consume them (Topology canvas).
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.FleetCatalog
  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboard.SwarmFeed
  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboardWeb.SnapshotView

  @privacy_session_key :privacy
  @selected_poll_ms 3_000

  def on_mount(:default, _params, session, socket) do
    default_swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    swarms = FleetCatalog.current()
    requested_swarm = session_swarm(session)
    swarm = if requested_swarm in swarms, do: requested_swarm, else: default_swarm
    default? = swarm == default_swarm
    privacy? = privacy_enabled?(session)

    if connected?(socket) do
      FleetCatalog.subscribe()

      if default? do
        SwarmFeed.subscribe()
        EventsFeed.subscribe()
      else
        send(self(), :poll_selected_swarm)
      end
    end

    # Seed from the feeds' caches so a fresh mount (page load, refresh, live nav)
    # renders the full menu + page immediately — without this, every view opened
    # with nil assigns and flashed the empty state ("Extension unavailable",
    # incomplete menu) for up to one poll interval (3s).
    cached_story = if default?, do: EventsFeed.current_story(), else: nil
    cached = if default?, do: SwarmFeed.view(%{dashboard_view: socket.view, story: cached_story})
    {status, revision, cached_snapshot} = cached || {:connecting, 0, nil}
    cached_inspect_lookup = inspect_lookup(cached_snapshot)
    dashboard_title = dashboard_title(cached_snapshot, swarm)

    socket =
      socket
      |> assign_new(:snapshot, fn -> cached_snapshot end)
      |> assign_new(:conn_status, fn -> status end)
      |> assign_new(:snapshot_revision, fn -> revision end)
      |> assign_new(:snapshot_notified_revision, fn -> revision end)
      |> assign_new(:feed_warning, fn -> nil end)
      |> assign_new(:dashboard_title, fn -> dashboard_title end)
      |> assign_new(:story, fn -> cached_story end)
      # the shared slide-over inspector (any page can open it via phx-click="inspect")
      |> assign_new(:inspect, fn -> nil end)
      |> assign_new(:inspect_transcript, fn -> nil end)
      |> assign_new(:inspect_activity, fn -> nil end)
      |> assign_new(:inspect_lookup, fn -> cached_inspect_lookup end)
      |> assign_new(:privacy, fn -> privacy? end)
      |> assign_new(:swarms, fn -> swarms end)
      # Sensitive-content gate: user conversations are NOT fetched (not merely
      # hidden) until revealed. Default comes from config; the TranscriptGate
      # JS hook replays a per-browser localStorage preference on every mount.
      |> assign_new(:reveal_transcripts, fn ->
        Application.get_env(:subzero_swarm_dashboard, :reveal_transcripts_default, false)
      end)
      |> assign(:swarm, swarm)
      |> attach_hook(:dash_feed, :handle_info, &handle_feed/2)
      |> attach_hook(:dash_inspect_evt, :handle_event, &handle_inspect_event/3)
      |> attach_hook(:dash_inspect_info, :handle_info, &handle_inspect_info/2)

    {:cont, socket}
  end

  defp session_swarm(session) when is_map(session) do
    Map.get(session, "selected_swarm", Map.get(session, :selected_swarm))
  end

  defp session_swarm(_session), do: nil

  defp privacy_enabled?(session) when is_map(session) do
    session
    |> Map.get("privacy", Map.get(session, @privacy_session_key))
    |> privacy_enabled?()
  end

  defp privacy_enabled?(true), do: true
  defp privacy_enabled?("true"), do: true
  defp privacy_enabled?(_), do: false

  # ── shared inspector: open on any page, close on Esc / click-away ────────────
  defp handle_inspect_event("inspect", %{"session_id" => submitted}, socket)
       when is_binary(submitted) and submitted != "" do
    sid = resolve_inspect_sid(socket, submitted)

    case find_session(socket.assigns[:snapshot], sid) do
      nil ->
        {:halt, socket}

      session ->
        if connected?(socket), do: send(self(), {:load_inspect_detail, sid})

        {:halt,
         assign(socket,
           inspect: session,
           inspect_transcript: :loading,
           inspect_activity: :loading
         )}
    end
  end

  defp handle_inspect_event("inspect_close", _params, socket),
    do: {:halt, assign(socket, inspect: nil, inspect_transcript: nil, inspect_activity: nil)}

  # Sensitive-content gate: flip, persist to the browser (push_event → hook →
  # localStorage), and — when the inspector sits open on gated placeholders —
  # fetch the real detail now instead of waiting for the next snapshot tick.
  defp handle_inspect_event("transcripts_reveal", _params, socket) do
    socket =
      socket |> assign(reveal_transcripts: true) |> push_event("transcripts:store", %{show: true})

    if connected?(socket) do
      if socket.assigns[:inspect],
        do: send(self(), {:load_inspect_detail, socket.assigns.inspect["session_id"]})

      # pages that lazy-load gated content on :load (session detail) refresh now
      send(self(), :load)
    end

    {:halt, socket}
  end

  defp handle_inspect_event("transcripts_hide", _params, socket) do
    # re-gate page-owned content (session detail) immediately, not on next tick
    if connected?(socket), do: send(self(), :load)

    {:halt,
     socket
     |> assign(reveal_transcripts: false)
     |> assign(
       inspect_transcript: socket.assigns[:inspect] && :hidden,
       inspect_activity: socket.assigns[:inspect] && :hidden
     )
     |> push_event("transcripts:store", %{show: false})}
  end

  # Not an inspector event — let the page's own handle_event run.
  defp handle_inspect_event(_event, _params, socket), do: {:cont, socket}

  @doc "Bidirectional, stable opaque targets; reordering a page cannot inspect the wrong user."
  def inspect_lookup(snapshot) do
    key = SubzeroSwarmDashboardWeb.Endpoint.config(:secret_key_base)

    by_sid =
      Map.new(session_rows(snapshot), fn row ->
        sid = row["session_id"]

        token =
          "inspect:" <> Base.url_encode64(:crypto.mac(:hmac, :sha256, key, sid), padding: false)

        {sid, token}
      end)

    %{by_sid: by_sid, by_token: Map.new(by_sid, fn {sid, token} -> {token, sid} end)}
  end

  def inspect_value(_lookup, false, sid), do: sid
  def inspect_value(%{by_sid: by_sid}, true, sid), do: Map.get(by_sid, sid)
  # Compatibility for extension hosts/tests passing the old opaque lookup.
  def inspect_value(lookup, true, sid) when is_map(lookup) and is_binary(sid),
    do: Enum.find_value(lookup, fn {token, value} -> if value == sid, do: token end)

  def inspect_value(_lookup, _privacy?, _sid), do: nil

  @doc "Project to sidebar chrome before privacy masking; unused tables never enter this walk."
  def layout_snapshot(snapshot, true) do
    snapshot
    |> SnapshotView.layout()
    |> PrivacyRedactor.mask_identity()
    |> restore_dashboard_page_labels(snapshot)
  end

  def layout_snapshot(snapshot, _privacy?), do: SnapshotView.layout(snapshot)

  def resolve_inspect_value(lookup, "inspect:" <> _ = submitted),
    do: Map.get(lookup[:by_token] || lookup, submitted)

  def resolve_inspect_value(_lookup, submitted), do: submitted

  defp resolve_inspect_sid(socket, submitted),
    do: resolve_inspect_value(socket.assigns[:inspect_lookup] || %{}, submitted)

  @doc "Re-query the shared source after a page, filter, tab or selection changes."
  def refresh_snapshot(socket) do
    opts = projection_opts(socket)
    default = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    cached = if socket.assigns[:swarm] == default, do: SwarmFeed.view(opts)

    case cached do
      {status, revision, snapshot} when is_map(snapshot) ->
        socket
        |> assign(snapshot_revision: revision, conn_status: status)
        |> put_snapshot(snapshot)

      {status, revision, nil} ->
        status =
          if socket.assigns[:snapshot] && status == :connecting, do: :disconnected, else: status

        assign(socket,
          conn_status: status,
          snapshot_revision: max(revision, socket.assigns[:snapshot_revision] || 0)
        )

      _ ->
        # Legacy publishers and non-default swarms provide a local source. The
        # default shared feed never assigns a complete snapshot to a LiveView.
        source = socket.assigns[:snapshot_source] || socket.assigns[:snapshot]

        socket =
          if (socket.assigns[:snapshot_revision] || 0) > 0,
            do: assign(socket, conn_status: :disconnected),
            else: socket

        put_snapshot(socket, SnapshotView.project(source, opts))
    end
  end

  defp projection_opts(socket) do
    socket.assigns
    |> Map.take([
      :q,
      :filter,
      :page,
      :page_id,
      :ext_sort,
      :ext_tab,
      :ext_page,
      :story,
      :session_id,
      :selected,
      :cid,
      :session_query
    ])
    |> Map.put(
      :inspect,
      if(socket.assigns[:inspect], do: Map.take(socket.assigns.inspect, ["session_id"]))
    )
    |> Map.put(:dashboard_view, socket.view)
  end

  defp put_snapshot(socket, snap) do
    assign(socket,
      snapshot: snap,
      snapshot_projected_at: System.monotonic_time(:millisecond),
      inspect_lookup: inspect_lookup(snap),
      dashboard_title: dashboard_title(snap, socket.assigns[:swarm])
    )
  end

  defp restore_dashboard_page_labels(masked, %{
         "extensions" => %{"dashboard_pages" => original_pages}
       })
       when is_map(masked) and is_list(original_pages) do
    case get_in(masked, ["extensions", "dashboard_pages"]) do
      masked_pages when is_list(masked_pages) ->
        put_in(
          masked,
          ["extensions", "dashboard_pages"],
          restore_page_labels(masked_pages, original_pages)
        )

      _ ->
        masked
    end
  end

  defp restore_dashboard_page_labels(masked, _original), do: masked

  defp restore_page_labels(masked_pages, original_pages) do
    original_by_index =
      original_pages
      |> Enum.with_index()
      |> Map.new(fn {page, index} -> {index, page} end)

    masked_pages
    |> Enum.with_index()
    |> Enum.map(fn {page, index} ->
      restore_page_label(page, Map.get(original_by_index, index))
    end)
  end

  # Restored verbatim EXCEPT for cid-shaped substrings — a page label is
  # operator chrome, but sweeping it keeps a careless host from leaking a cid.
  defp restore_page_label(%{} = masked_page, %{"label" => label}),
    do: Map.put(masked_page, "label", PrivacyRedactor.mask_cid(label))

  defp restore_page_label(masked_page, _original_page), do: masked_page

  # Lazily fetch the full session detail (durable transcript + raw slot activity),
  # so the inspector shows everything the dedicated page does. Ignore if the user
  # already moved on (closed it or opened a different session).
  defp handle_inspect_info({:load_inspect_detail, sid}, socket) do
    # gate BEFORE the fetch: hidden conversations never leave the swarm API
    if socket.assigns[:reveal_transcripts] do
      swarm = socket.assigns.swarm
      transcript = SwarmClient.session_history(swarm, sid)
      activity = SwarmClient.session_logs(swarm, sid)

      if socket.assigns[:inspect] && socket.assigns.inspect["session_id"] == sid do
        {:halt, assign(socket, inspect_transcript: transcript, inspect_activity: activity)}
      else
        {:halt, socket}
      end
    else
      {:halt, assign(socket, inspect_transcript: :hidden, inspect_activity: :hidden)}
    end
  end

  # Per-snapshot inspector refresh: the ephemeral slot activity is THE live panel,
  # so it re-fetches every tick; the durable transcript only changes when the
  # session actually moved, so it re-fetches only when the roster row did.
  defp handle_inspect_info({:refresh_inspect, sid, row_changed?}, socket) do
    if socket.assigns[:reveal_transcripts] and socket.assigns[:inspect] != nil and
         socket.assigns.inspect["session_id"] == sid do
      swarm = socket.assigns.swarm
      socket = assign(socket, inspect_activity: SwarmClient.session_logs(swarm, sid))

      socket =
        if row_changed?,
          do: assign(socket, inspect_transcript: SwarmClient.session_history(swarm, sid)),
          else: socket

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_inspect_info(_msg, socket), do: {:cont, socket}

  defp session_rows(nil), do: []

  defp session_rows(snapshot) do
    ((snapshot["sessions"] || []) ++ (snapshot["_context_sessions"] || []))
    |> Enum.filter(&(is_map(&1) and is_binary(&1["session_id"])))
    |> Enum.uniq_by(& &1["session_id"])
  end

  defp find_session(snapshot, sid),
    do: Enum.find(session_rows(snapshot), &(&1["session_id"] == sid))

  # {:cont} so pages that need a side-effect on new snapshots (e.g. Topology pushing
  # the graph to its JS hook) can also react; @snapshot is assigned here regardless.
  defp handle_feed(:poll_selected_swarm, socket) do
    Process.send_after(self(), :poll_selected_swarm, @selected_poll_ms)

    case SwarmClient.dashboard(socket.assigns.swarm) do
      {:ok, snapshot} -> send(self(), {:snapshot, snapshot})
      {:error, reason} -> send(self(), {:disconnected, reason})
    end

    {:halt, socket}
  end

  defp handle_feed({:swarms, swarms}, socket),
    do: {:halt, assign(socket, :swarms, swarms)}

  defp handle_feed({:snapshot_ready, revision}, socket) do
    if revision > (socket.assigns[:snapshot_notified_revision] || 0) do
      socket = socket |> refresh_snapshot() |> refresh_inspector()
      {:cont, assign(socket, snapshot_notified_revision: socket.assigns.snapshot_revision)}
    else
      {:halt, socket}
    end
  end

  # Compatibility for selected-swarm polling and explicit external publishers.
  defp handle_feed({:snapshot, snap}, socket) do
    socket = socket |> assign(snapshot_source: snap, conn_status: :connected)
    snapshot = SnapshotView.project(snap, projection_opts(socket))
    {:cont, socket |> put_snapshot(snapshot) |> refresh_inspector()}
  end

  defp handle_feed({:disconnected, revision, _reason}, socket) do
    if revision > (socket.assigns[:snapshot_revision] || 0),
      do: {:halt, refresh_snapshot(socket)},
      else: {:halt, socket}
  end

  defp handle_feed({:disconnected, _reason}, socket),
    do: {:halt, assign(socket, conn_status: :disconnected)}

  defp handle_feed({:warning, w}, socket),
    do: {:halt, assign(socket, feed_warning: w)}

  # {:cont} like {:snapshot}: the Events page stream-prepends new story rows in
  # its own handle_info; @story is assigned here regardless.
  defp handle_feed({:story, summary}, socket) do
    previous = socket.assigns[:story]
    socket = assign(socket, story: summary)
    elapsed = System.monotonic_time(:millisecond) - (socket.assigns[:snapshot_projected_at] || 0)

    changed? =
      SubzeroSwarmDashboardWeb.ReplyHealth.suppressed_by_cid(previous) !=
        SubzeroSwarmDashboardWeb.ReplyHealth.suppressed_by_cid(summary)

    # Reclassify the complete cached roster even during an upstream outage.
    # Keep normal story ticks cheap; suppression changes must update immediately.
    socket =
      if socket.assigns[:snapshot] && (changed? or elapsed >= @selected_poll_ms),
        do: refresh_snapshot(socket),
        else: socket

    {:cont, socket}
  end

  # Raw display events flow through to pages that consume them (Topology canvas).
  defp handle_feed({:display_event, _ev}, socket), do: {:cont, socket}

  # Live WS events flow through to pages (every page has a catch-all handle_info/2;
  # Topology consumes them for instant graph updates). SwarmFeed also observes them
  # (it subscribes to "feed") for the silent-empty guard.
  # Non-feed messages (e.g. a page's own :load_usage) also pass through.
  defp handle_feed(_other, socket), do: {:cont, socket}

  defp refresh_inspector(socket) do
    snap = socket.assigns.snapshot
    # Keep the open inspector live: its header follows the fresh roster row, and
    # {:refresh_inspect} re-fetches the detail (activity always, transcript only
    # on a row change) without a loading flash.
    socket =
      with %{"session_id" => sid} = prev <- socket.assigns[:inspect],
           %{} = fresh <- find_session(snap, sid) do
        if connected?(socket), do: send(self(), {:refresh_inspect, sid, fresh != prev})
        assign(socket, inspect: fresh)
      else
        _ -> socket
      end

    socket
  end

  @doc """
  Host-provided title, else a titleized swarm name. Public because `Layouts.app`
  derives the sidebar title from the same rule (it receives the snapshot as an
  attr, not this hook's assign).
  """
  def dashboard_title(%{"dashboard_title" => title} = snapshot, swarm) when is_binary(title) do
    case String.trim(title) do
      "" -> dashboard_title(Map.delete(snapshot, "dashboard_title"), swarm)
      title -> title
    end
  end

  def dashboard_title(%{"swarm" => swarm}, _swarm), do: titleize_swarm(swarm)
  def dashboard_title(_snapshot, swarm), do: titleize_swarm(swarm)

  defp titleize_swarm(swarm) do
    swarm
    |> to_string()
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    |> case do
      "" -> "Swarm Console"
      title -> title
    end
  end
end
