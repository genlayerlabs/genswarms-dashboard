defmodule SubzeroSwarmDashboardWeb.SessionDetailLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.SwarmClient

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cid = decode_id(id)
    if connected?(socket), do: send(self(), :load)

    {:ok,
     assign(socket,
       page_title: "Session #{cid}",
       session_id: cid,
       transcript: :loading,
       activity: :loading,
       skills: :loading,
       requests: :loading
     )}
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
  def handle_info(:load, socket) do
    swarm = socket.assigns.swarm
    id = socket.assigns.session_id
    # sensitive gate (DashHooks assign): conversations aren't fetched until
    # revealed — requests/skills carry no user content and always load
    reveal? = socket.assigns[:reveal_transcripts]

    {:noreply,
     socket
     |> assign(
       transcript: if(reveal?, do: SwarmClient.session_history(swarm, id), else: :hidden),
       activity: if(reveal?, do: SwarmClient.session_logs(swarm, id), else: :hidden),
       requests: load_requests(id)
     )
     # skills = the agent's system-prompt source, read from its disk — it only
     # changes on a skills redeploy, so ONE fetch at load, not one per 3s tick
     |> assign_new_skills(swarm, id)}
  end

  # Live refresh: re-fetch transcript + activity + requests when THIS session
  # moved — not on every 3s snapshot tick. Each :load is 3 HTTP round-trips to
  # the backend (over a VPN for a remote swarm), so an idle conversation left
  # open in a tab must not poll forever; `last_activity` is the change signal.
  def handle_info({:snapshot, snap}, socket) do
    last = session_last_activity(snap, socket.assigns.session_id)

    if connected?(socket) and last != socket.assigns[:last_activity_seen] do
      send(self(), :load)
      {:noreply, assign(socket, last_activity_seen: last)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Fetch skills only while they're still :loading; a retry is free on the next
  # tick if the first read failed (agent slot not up yet).
  defp assign_new_skills(socket, swarm, id) do
    case socket.assigns.skills do
      {:ok, _} -> socket
      _ -> assign(socket, skills: SwarmClient.session_skills(swarm, id))
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :session, find_session(assigns[:snapshot], assigns.session_id))

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:sessions}
      swarm={@swarm}
      snapshot={@snapshot}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5 max-w-3xl">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/sessions"} class="btn btn-ghost btn-xs gap-1">
            <.icon name="hero-arrow-left" class="size-3.5" /> Sessions
          </.link>
        </div>

        <div class="flex items-center justify-between gap-4 flex-wrap">
          <.identity user={@session && @session["user"]} session_id={@session_id} label={@session && @session["label"]} size={:lg} />
          <.live_dot :if={@session} state={@session["state"]} label />
        </div>

        <div :if={@session} class="flex flex-wrap gap-2 text-sm">
          <span class="badge badge-ghost font-mono text-xs">{@session_id}</span>
          <span class="badge badge-ghost">{@session["transport"]}</span>
          <span class="badge badge-ghost">agent {@session["agent"]}</span>
          <span
            :for={{k, v} <- @session["transport_ref"] || %{}}
            class="badge badge-outline font-mono text-xs"
          >
            {k}={v}
          </span>
        </div>

        <.prompt_skills skills={@skills} />

        <.panel id="session-requests" title="Requests">
          <:meta>
            <span class="font-mono">event feed</span>
          </:meta>
          <p class="text-xs opacity-50 mb-3">
            Each request this conversation opened, exactly as the display-event feed
            recorded it — open, claim, first feedback, reply. <strong>Exact facts</strong>,
            no log guessing.
          </p>
          <.requests requests={@requests} story={@story} />
        </.panel>

        <.panel title="Conversation">
          <p class="text-xs opacity-50 mb-3">
            The clean user ↔ Wingston back-and-forth, saved to the database — it <strong>survives agent restarts</strong>. (Empty if persistence is off.)
          </p>
          <.transcript transcript={@transcript} />
        </.panel>

        <.panel title="Agent activity">
          <:meta>
            <span class="inline-flex items-center gap-1.5">
              <span class="signal-dot"></span> live
            </span>
          </:meta>
          <p class="text-xs opacity-50 mb-3">
            The agent's raw working log for this slot right now — messages in, tool
            calls, results, sends. <strong>Ephemeral</strong>: wiped when the slot is recycled.
          </p>
          <.activity_timeline activity={@activity} />
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :skills, :any, required: true

  # The agent's system prompt source — the skills dir subzeroclaw concatenates into
  # its system message at session start, read live from an agent slot's disk (no
  # log entry involved). Standout accent card, sits first because the model saw it
  # before any turn; each skill collapsed since the full text dwarfs the conversation.
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
      <details :for={s <- @skills_list} class="group mt-1">
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

  defp transcript(%{transcript: {:ok, %{"turns" => turns, "source" => source}}} = assigns)
       when turns != [] do
    assigns = assign(assigns, turns: turns, source: source)

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <span class="text-xs opacity-60">
        {if @source == "store", do: "saved to the database · survives restarts", else: "source: #{@source}"}
      </span>
      <button type="button" phx-click="transcripts_hide" class="btn btn-ghost btn-xs gap-1 opacity-60">
        <.icon name="hero-eye-slash" class="size-3.5" /> hide
      </button>
    </div>
    <.conversation id="session-conversation" turns={@turns} />
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
  defp find_session(snap, id), do: Enum.find(snap["sessions"] || [], &(&1["session_id"] == id))

  # The change signal for the refetch gate. A session missing from the snapshot
  # (evicted/idle-trimmed) yields nil — which still differs from a previous
  # value exactly once, so the page does one final refresh and then rests.
  defp session_last_activity(snap, id) do
    case find_session(snap, id) do
      %{"last_activity" => la} -> la
      _ -> nil
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
