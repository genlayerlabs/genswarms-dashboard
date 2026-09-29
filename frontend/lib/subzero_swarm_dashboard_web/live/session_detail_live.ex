defmodule SubzeroSwarmDashboardWeb.SessionDetailLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboardWeb.DashHooks

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cid = decode_id(id)
    if connected?(socket), do: send(self(), :load)

    {:ok,
     socket
     |> assign(
       page_title: "Session #{display_session_id(cid, socket.assigns[:privacy] == true)}",
       session_id: cid,
       transcript: :loading,
       activity: :loading,
       skills: :loading,
       requests: :loading,
       detail_loading: MapSet.new(),
       detail_pending: MapSet.new(),
       detail_errors: MapSet.new()
     )
     |> DashHooks.refresh_snapshot()
     |> then(fn socket ->
       assign(socket, :last_activity_seen, session_last_activity(socket.assigns.snapshot, cid))
     end)}
  end

  # Session cids may carry colons (scheme-prefixed transport ids) — they trip Plug.Static (InvalidPathError) when
  # used as a raw path segment, so SessionsLive URL-safe-base64-encodes them in the link. Decode
  # here; fall back to the raw value for any link that wasn't encoded.
  defp decode_id(id) do
    case Base.url_decode64(id, padding: false) do
      {:ok, cid} -> if String.printable?(cid) and String.contains?(cid, ":"), do: cid, else: id
      :error -> id
    end
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, load_details(socket)}

  # Live refresh: re-fetch transcript + activity + requests when THIS session
  # moved — not on every 3s snapshot tick. Each :load is 3 HTTP round-trips to
  # the backend (over a VPN for a remote swarm), so an idle conversation left
  # open in a tab must not poll forever; `last_activity` is the change signal.
  def handle_info({:snapshot, snap}, socket) do
    last = session_last_activity(snap, socket.assigns.session_id)

    if connected?(socket) and last != socket.assigns[:last_activity_seen] do
      {:noreply, socket |> assign(last_activity_seen: last) |> load_details(true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:snapshot_ready, _revision}, socket),
    do: handle_info({:snapshot, socket.assigns.snapshot}, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh_session", _, socket), do: {:noreply, load_details(socket)}

  # One independent task per section keeps slow slot/log reads out of the
  # LiveView mailbox. A changing session queues at most one follow-up per task.
  defp load_details(socket, changed? \\ false) do
    Enum.reduce([:transcript, :activity, :requests, :skills], socket, fn key, socket ->
      cond do
        key in [:transcript, :activity] and !socket.assigns.reveal_transcripts ->
          socket
          |> cancel_async(key)
          |> assign(key, :hidden)
          |> update(:detail_loading, &MapSet.delete(&1, key))
          |> update(:detail_pending, &MapSet.delete(&1, key))
          |> update(:detail_errors, &MapSet.delete(&1, key))

        key == :skills and match?({:ok, _}, socket.assigns.skills) ->
          socket

        MapSet.member?(socket.assigns.detail_loading, key) ->
          if changed? and key != :skills,
            do: update(socket, :detail_pending, &MapSet.put(&1, key)),
            else: socket

        true ->
          load_detail(socket, key)
      end
    end)
  end

  defp load_detail(socket, key) do
    swarm = socket.assigns.swarm
    id = socket.assigns.session_id

    socket =
      if socket.assigns[key] == :hidden or match?({:error, _}, socket.assigns[key]),
        do: assign(socket, key, :loading),
        else: socket

    socket
    |> update(:detail_loading, &MapSet.put(&1, key))
    |> start_async(key, fn ->
      case key do
        :transcript -> SwarmClient.session_history(swarm, id)
        :activity -> SwarmClient.session_logs(swarm, id)
        :skills -> SwarmClient.session_skills(swarm, id)
        :requests -> load_requests(id)
      end
    end)
  end

  @impl true
  def handle_async(key, {:ok, result}, socket) do
    socket = update(socket, :detail_loading, &MapSet.delete(&1, key))

    socket =
      cond do
        key in [:transcript, :activity] and !socket.assigns.reveal_transcripts ->
          assign(socket, key, :hidden)

        match?({:error, _}, result) ->
          socket = update(socket, :detail_errors, &MapSet.put(&1, key))
          # Preserve the last successful data during a failed refresh.
          if socket.assigns[key] in [:loading, :hidden],
            do: assign(socket, key, result),
            else: socket

        true ->
          socket |> assign(key, result) |> update(:detail_errors, &MapSet.delete(&1, key))
      end

    pending? = MapSet.member?(socket.assigns.detail_pending, key)
    socket = update(socket, :detail_pending, &MapSet.delete(&1, key))

    if pending? and (key not in [:transcript, :activity] or socket.assigns.reveal_transcripts) do
      {:noreply, load_detail(socket, key)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(key, {:exit, _reason}, socket),
    do: handle_async(key, {:ok, {:error, :unavailable}}, socket)

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true

    assigns =
      assigns
      |> assign(:session, find_session(assigns[:snapshot], assigns.session_id))
      |> assign(:display_session_id, display_session_id(assigns.session_id, privacy?))
      |> assign(:layout_snapshot, DashHooks.layout_snapshot(assigns[:snapshot], privacy?))

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
      <div id="session-detail" class="mx-auto w-full max-w-4xl space-y-4">
        <div class="flex items-center justify-between gap-2">
          <.link navigate={~p"/sessions"} class="btn btn-ghost btn-xs gap-1">
            <.icon name="hero-arrow-left" class="size-3.5" /> Sessions
          </.link>
          <button
            id="session-refresh"
            type="button"
            phx-click="refresh_session"
            disabled={MapSet.size(@detail_loading) > 0}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 px-3 py-1.5 text-xs hover:bg-base-200 disabled:opacity-50"
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
            {if MapSet.size(@detail_loading) > 0, do: "Refreshing…", else: "Refresh"}
          </button>
        </div>

        <div class="flex items-center justify-between gap-4 flex-wrap">
          <%= if @privacy do %>
            <.identity_avatar
              user={@session && @session["user"]}
              session_id={@session_id}
              label={@session && @session["label"]}
              privacy={@privacy}
              size={:lg}
            />
          <% else %>
            <.identity
              user={@session && @session["user"]}
              session_id={@session_id}
              label={@session && @session["label"]}
              size={:lg}
            />
          <% end %>
          <.live_dot :if={@session} state={@session["state"]} label />
        </div>

        <div :if={@session} class="flex flex-wrap gap-2 text-sm">
          <span :if={!@privacy} class="badge badge-ghost font-mono text-xs">{@session_id}</span>
          <span class="badge badge-ghost">{@session["transport"]}</span>
          <span :if={@session["agent"]} class="badge badge-ghost">agent {@session["agent"]}</span>
          <span
            :for={{k, v} <- @session["transport_ref"] || %{}}
            :if={!@privacy}
            class="badge badge-outline font-mono text-xs"
          >
            {k}={v}
          </span>
        </div>

        <.panel id="session-chat-panel" title="Conversation">
          <:meta>
            <span :if={MapSet.member?(@detail_loading, :transcript)} role="status">Updating…</span>
          </:meta>
          <p class="text-xs opacity-60 mb-3">
            Latest 40 saved turns. Older history is not loaded here.
          </p>
          <.detail_error key={:transcript} errors={@detail_errors} />
          <.transcript transcript={@transcript} privacy={@privacy} />
        </.panel>

        <div class="space-y-2">
          <details
            id="session-requests-details"
            phx-mounted={JS.ignore_attributes("open")}
            class="rounded-xl border border-base-300"
          >
            <summary class="cursor-pointer px-4 py-3 text-sm font-medium hover:bg-base-200/50">
              Requests <span class="ml-2 text-xs font-normal opacity-50">Response timing</span>
            </summary>
            <.panel id="session-requests" title="Requests" class="border-0 shadow-none">
              <p class="text-xs opacity-50 mb-3">
                Recorded request events: open, claim, first feedback and reply.
              </p>
              <.detail_error key={:requests} errors={@detail_errors} />
              <div
                class="max-h-[50vh] overflow-auto scroll-thin"
                tabindex="0"
                role="region"
                aria-label="Request history"
              >
                <.requests requests={@requests} story={@story} />
              </div>
            </.panel>
          </details>

          <details
            id="session-activity-details"
            phx-mounted={JS.ignore_attributes("open")}
            class="rounded-xl border border-base-300"
          >
            <summary class="cursor-pointer px-4 py-3 text-sm font-medium hover:bg-base-200/50">
              Agent activity
              <span class="ml-2 text-xs font-normal opacity-50">Temporary working log</span>
            </summary>
            <.panel title="Agent activity" class="border-0 shadow-none">
              <p class="text-xs opacity-50 mb-3">
                Messages, tool calls and results for the current agent slot. Wiped when the slot is recycled.
              </p>
              <.detail_error key={:activity} errors={@detail_errors} />
              <div
                class="max-h-[50vh] overflow-auto scroll-thin"
                tabindex="0"
                role="region"
                aria-label="Agent activity"
              >
                <.activity_timeline activity={@activity} privacy={@privacy} />
              </div>
            </.panel>
          </details>

          <details
            id="session-skills-details"
            phx-mounted={JS.ignore_attributes("open")}
            class="rounded-xl border border-base-300"
          >
            <summary class="cursor-pointer px-4 py-3 text-sm font-medium hover:bg-base-200/50">
              System prompt · skills
              <span class="ml-2 text-xs font-normal opacity-50">Agent instructions</span>
            </summary>
            <div class="p-3 pt-0">
              <.detail_error key={:skills} errors={@detail_errors} />
              <.prompt_skills skills={@skills} />
            </div>
          </details>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :key, :atom, required: true
  attr :errors, :any, required: true

  defp detail_error(assigns) do
    ~H"""
    <p
      :if={MapSet.member?(@errors, @key)}
      id={"session-#{@key}-error"}
      role="status"
      class="mb-3 rounded-lg border border-warning/30 bg-warning/10 p-2 text-xs"
    >
      Could not refresh this section. Any previous data is kept below. Use Refresh to retry.
    </p>
    """
  end

  attr :skills, :any, required: true

  # The agent's system prompt source — the skills dir subzeroclaw concatenates into
  # its system message at session start, read live from an agent slot's disk.
  # Keep it inside diagnostics: the full text dwarfs the conversation.
  # source "slot" = this session's leased agent; "pool" = the lease is gone, so the
  # backend read another live pool agent (same skills deploy).
  defp prompt_skills(%{skills: {:ok, %{"skills" => [_ | _] = skills} = body}} = assigns) do
    assigns = assign(assigns, skills_list: skills, source: body["source"])

    ~H"""
    <.panel title="System prompt · skills" class="border-l-4 border-accent bg-accent/10">
      <p class="text-xs opacity-50 mb-2">
        What the agent is primed with before the first message — every skill file
        loaded into its system prompt (read live from the agent's skills dir).
      </p>
      <p :if={@source == "pool"} class="text-xs opacity-50 mb-2">
        This session isn't leased to a slot right now — showing the skills another live
        pool agent is primed with (the pool shares one skills deploy).
      </p>
      <details
        :for={{s, i} <- Enum.with_index(@skills_list)}
        id={"session-skill-#{i}"}
        phx-mounted={JS.ignore_attributes("open")}
        class="group mt-1"
      >
        <summary class="flex items-baseline gap-2 cursor-pointer list-none text-xs">
          <span class="badge badge-accent badge-outline badge-xs font-mono">{s["name"]}</span>
          <span class="opacity-40 group-open:rotate-90 transition-transform">›</span>
        </summary>
        <pre class="mt-1 text-xs whitespace-pre-wrap break-words bg-base-300/40 rounded p-2 overflow-x-auto max-h-96 overflow-y-auto">{s["content"]}</pre>
      </details>
    </.panel>
    """
  end

  defp prompt_skills(%{skills: :loading} = assigns) do
    ~H"""
    <.panel title="System prompt · skills">
      <div class="text-sm opacity-60">loading…</div>
    </.panel>
    """
  end

  # No live agent anywhere to read skills from (swarm down / pool empty) — say so
  # rather than render an empty standout card.
  defp prompt_skills(assigns) do
    ~H"""
    <.panel title="System prompt · skills">
      <div class="text-sm opacity-60">Unavailable (no live agent to read skills from).</div>
    </.panel>
    """
  end

  attr :transcript, :any, required: true
  attr :privacy, :boolean, default: false

  defp transcript(%{transcript: {:ok, %{"turns" => turns, "source" => source}}} = assigns)
       when turns != [] do
    assigns = assign(assigns, turns: turns, source: source)

    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
      <span class="text-xs opacity-60">
        {if @source == "store",
          do: "saved to the database · survives restarts",
          else: "source: #{@source}"}
      </span>
      <div class="flex items-center gap-2">
        <button
          id="session-jump-latest"
          type="button"
          phx-click={JS.dispatch("scroll:bottom", to: "#session-conversation-scroll")}
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-base-200"
        >
          <.icon name="hero-arrow-down" class="size-3.5" /> Latest
        </button>
        <button
          type="button"
          phx-click="transcripts_hide"
          class="btn btn-ghost btn-xs gap-1 opacity-60"
        >
          <.icon name="hero-eye-slash" class="size-3.5" /> hide
        </button>
      </div>
    </div>
    <div
      id="session-conversation-scroll"
      phx-hook="ScrollBottom"
      class="h-[clamp(16rem,55dvh,40rem)] overflow-auto scroll-thin rounded-lg bg-base-200/30 p-3 focus-visible:outline-2 focus-visible:outline-primary"
      tabindex="0"
      role="region"
      aria-label="Saved conversation"
    >
      <.conversation id="session-conversation" turns={@turns} privacy={@privacy} />
    </div>
    """
  end

  defp transcript(%{transcript: {:ok, %{"source" => source}}} = assigns) do
    assigns = assign(assigns, :source, source)

    ~H"""
    <div class="text-sm opacity-60">No transcript ({@source}).</div>
    """
  end

  defp transcript(%{transcript: :loading} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">loading…</div>
    """
  end

  defp transcript(%{transcript: :hidden} = assigns) do
    ~H"""
    <.sensitive_reveal />
    """
  end

  defp transcript(assigns) do
    ~H"""
    <div class="text-sm opacity-60">Transcript unavailable.</div>
    """
  end

  defp find_session(nil, _id), do: nil

  defp find_session(snap, id),
    do:
      Enum.find(
        (snap["sessions"] || []) ++ (snap["_context_sessions"] || []),
        &(&1["session_id"] == id)
      )

  # The change signal for the refetch gate. A session missing from the snapshot
  # (evicted/idle-trimmed) yields nil — which still differs from a previous
  # value exactly once, so the page does one final refresh and then rests.
  defp session_last_activity(snap, id) do
    case find_session(snap, id) do
      %{"last_activity" => la} -> la
      _ -> nil
    end
  end

  defp display_session_id(nil, _privacy?), do: nil
  defp display_session_id(sid, false), do: sid

  defp display_session_id(sid, true) when is_binary(sid) do
    case PrivacyRedactor.mask_cid(sid) do
      ^sid -> "•••"
      masked -> masked
    end
  end

  # ── REQUESTS: the event-derived lifecycle for this cid (spec §5.6) ──────────
  # Episodes come from the EventsFeed fold, newest first, refreshed on the same
  # snapshot pulse as the transcript. The claim delta is read from the cid's
  # `routed` story row while it's still in the ring; legs the fold never
  # recorded are simply not claimed — nothing is inferred.
  defp load_requests(cid) do
    rows = EventsFeed.story_ring() |> Enum.filter(&(&1[:cid] == cid))
    Enum.map(EventsFeed.episodes(cid), &request_row(&1, rows))
  catch
    # the feed isn't running (disabled / not yet supervised) — same face as an
    # empty feed: nothing observed
    :exit, _ -> []
  end

  defp request_row(ep, rows) do
    claim =
      rows
      |> Enum.filter(fn r ->
        r[:kind] == "routed" and is_number(r[:ts]) and r[:ts] >= ep.opened_at and
          (ep.done_at == nil or r[:ts] <= ep.done_at)
      end)
      # rows are newest-first; the claim is the episode's earliest routed row
      |> List.last()

    %{
      opened_at: ep.opened_at,
      stalled: ep.stalled,
      queued: ep.count - 1,
      chain: chain(ep, claim)
    }
  end

  defp chain(ep, claim) do
    claim_leg =
      cond do
        is_map(claim) -> "⟳ claim #{duration(claim[:ts] - ep.opened_at)}"
        is_binary(ep.agent) -> "⟳ claim by #{ep.agent}"
        true -> nil
      end

    # only a feedback that PRECEDED the close — when the reply itself was the
    # first thing the user saw, the verdict leg already says it
    feedback_leg =
      if ep.first_sent && (ep.done_at == nil or ep.first_sent < ep.done_at),
        do: "✉ first feedback #{duration(ep.first_sent - ep.opened_at)}"

    verdict_leg =
      cond do
        ep.done -> "✓ replied #{duration(ep.duration)}"
        ep.stalled -> "⚠ stalled — no reply"
        true -> "… awaiting reply"
      end

    ["open", claim_leg, feedback_leg, verdict_leg]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" → ")
  end

  attr :requests, :any, required: true
  attr :story, :any, default: nil

  defp requests(%{requests: :loading} = assigns) do
    ~H"""
    <div class="text-sm opacity-60">loading…</div>
    """
  end

  defp requests(%{requests: [_ | _]} = assigns) do
    ~H"""
    <div class="divide-y divide-base-300/40 font-mono text-xs">
      <div
        :for={{r, i} <- Enum.with_index(@requests)}
        id={"session-request-#{i}"}
        class={[
          "flex flex-wrap items-baseline gap-x-2 py-1.5 first:pt-0 last:pb-0 border-l-2 pl-2.5",
          request_tone(r)
        ]}
      >
        <span class="opacity-50 tnum whitespace-nowrap">
          <.local_time id={"session-request-#{i}-t"} ts={r.opened_at} fmt="hms" />
        </span>
        <span class={[r.stalled && "text-warning"]}>{r.chain}</span>
        <span :if={r.queued > 0} class="opacity-60">·+{r.queued} queued</span>
      </div>
    </div>
    <p class="text-xs opacity-40 mt-2">
      (requests observed since <.local_time id="requests-since" ts={@story[:baseline_at]} />)
    </p>
    """
  end

  defp requests(%{requests: {:error, _}} = assigns) do
    ~H"""
    <p class="text-sm opacity-60">Request history unavailable.</p>
    """
  end

  defp requests(assigns) do
    ~H"""
    <div id="session-requests-empty">
      <.empty_state msg="No requests observed for this conversation" />
      <p class="text-xs opacity-40 mt-2">
        (requests observed since <.local_time id="requests-since-empty" ts={@story[:baseline_at]} />).
      </p>
    </div>
    """
  end

  # the verdict leg keys the row's left accent — the same scan-by-color grammar
  # as the Events story rows (success = replied, warning = stalled, primary = open)
  defp request_tone(%{chain: chain} = r) do
    cond do
      String.contains?(chain, "✓ replied") -> "border-success/60"
      r.stalled -> "border-warning/70"
      true -> "border-primary/50"
    end
  end
end
