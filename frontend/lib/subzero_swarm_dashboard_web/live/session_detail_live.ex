defmodule SubzeroSwarmDashboardWeb.SessionDetailLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboard.EventsFeed
  alias SubzeroSwarmDashboard.SessionEvidence
  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboardWeb.CoreComponents
  alias SubzeroSwarmDashboardWeb.DashHooks

  @request_event_kinds ["request_open", "routed", "progress_sent", "reply_sent", "teardown"]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cid = decode_id(id)
    if connected?(socket), do: send(self(), :load)

    {:ok,
     assign(socket,
       page_title: "Session #{display_session_id(cid, socket.assigns[:privacy] == true)}",
       session_id: cid,
       route_id: Base.url_encode64(cid, padding: false),
       active_tab: :conversation,
       transcript: :loading,
       activity: :loading,
       skills: :loading,
       requests: :loading,
       request_refresh_pending: false,
       evidence:
         SessionEvidence.build(transcript: :loading, activity: :loading, skills: :loading),
       activity_rows: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :active_tab, tab(Map.get(params, "tab")))}
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

    transcript = if reveal?, do: SwarmClient.session_history(swarm, id), else: :hidden
    activity = if reveal?, do: SwarmClient.session_logs(swarm, id), else: :hidden

    socket =
      socket
      |> assign(transcript: transcript, activity: activity, requests: load_requests(id))
      # skills = the agent's system-prompt source, read from its disk — it only
      # changes on a skills redeploy, so ONE fetch at load, not one per 3s tick
      |> assign_new_skills(swarm, id)
      |> assign_evidence_and_activity_rows()

    {:noreply, socket}
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

  # Display events from one poll are followed by one folded story summary from
  # the same sender. Mark the batch dirty here and perform one refresh when that
  # summary arrives; refreshing per event multiplies synchronous feed calls.
  def handle_info(
        {:display_event, %{"cid" => cid, "kind" => kind}},
        %{assigns: %{session_id: cid}} = socket
      )
      when kind in @request_event_kinds do
    {:noreply, assign(socket, request_refresh_pending: true)}
  end

  # DashHooks assigns every folded story summary before continuing here. Refresh
  # the full per-cid episodes only when that small summary proves this session's
  # lifecycle changed. This keeps an already-open detail page current without
  # pulling the story rings on every 700ms feed tick.
  def handle_info({:story, summary}, socket) do
    if socket.assigns.request_refresh_pending or
         request_state_changed?(
           socket.assigns.requests,
           summary,
           socket.assigns.session_id
         ) do
      {:noreply,
       assign(socket,
         requests: load_requests(socket.assigns.session_id),
         request_refresh_pending: false
       )}
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

  # Transcript/activity/skills change only on :load. Derive their metadata and
  # timeline rows once here instead of rescanning an unbounded slot log on every
  # 700ms story tick that happens to re-render this LiveView.
  defp assign_evidence_and_activity_rows(socket) do
    privacy? = socket.assigns[:privacy] == true

    assign(socket,
      evidence:
        SessionEvidence.build(
          transcript: socket.assigns.transcript,
          activity: socket.assigns.activity,
          skills: socket.assigns.skills
        ),
      activity_rows: CoreComponents.activity_rows(socket.assigns.activity, privacy?)
    )
  end

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    reveal? = assigns[:reveal_transcripts] == true

    transcript = if reveal?, do: assigns.transcript, else: :hidden
    activity = if reveal?, do: assigns.activity, else: :hidden

    evidence =
      if reveal? do
        assigns.evidence
      else
        SessionEvidence.build(transcript: :hidden, activity: :hidden, skills: assigns.skills)
      end

    assigns =
      assigns
      |> assign(:transcript, transcript)
      |> assign(:activity, activity)
      |> assign(:activity_rows, if(reveal?, do: assigns.activity_rows, else: nil))
      |> assign(:evidence, evidence)
      |> assign(:session, find_session(assigns[:snapshot], assigns.session_id))
      |> assign(:display_session_id, display_session_id(assigns.session_id, privacy?))
      |> assign(:layout_snapshot, DashHooks.layout_snapshot(assigns[:snapshot], privacy?))
      |> assign(:latest_request, latest_request(assigns.requests))
      |> assign(:requests_since, requests_since(assigns.requests, assigns[:story]))

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
      <div class="space-y-5 max-w-6xl">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/sessions"} class="btn btn-ghost btn-xs gap-1">
            <.icon name="hero-arrow-left" class="size-3.5" /> Sessions
          </.link>
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
          <span class="badge badge-ghost">agent {@session["agent"]}</span>
          <span
            :for={{k, v} <- @session["transport_ref"] || %{}}
            :if={!@privacy}
            class="badge badge-outline font-mono text-xs"
          >
            {k}={v}
          </span>
        </div>

        <div
          id="session-status-summary"
          class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4"
        >
          <.status_fact
            id="session-request-status"
            label="Latest request"
            value={request_status(@latest_request)}
            tone={request_tone_name(@latest_request)}
          />
          <.status_fact
            id="session-context-status"
            label="Context evidence"
            value={evidence_label(@evidence.availability)}
            tone={evidence_tone(@evidence.availability)}
          />
          <.status_fact
            id="session-compaction-status"
            label="Compaction"
            value={compaction_label(@evidence.compaction.state)}
            tone={compaction_tone(@evidence.compaction.state)}
          />
          <.status_fact
            id="session-last-activity"
            label="Last activity"
            value={last_activity_label(@session)}
            tone={:neutral}
          />
        </div>

        <nav
          id="session-tabs"
          role="tablist"
          aria-label="Session detail"
          class="tabs tabs-border overflow-x-auto whitespace-nowrap"
        >
          <.link
            :for={{key, label} <- session_tabs()}
            id={"session-tab-#{key}"}
            role="tab"
            aria-selected={to_string(@active_tab == key)}
            patch={tab_path(@route_id, key, @privacy)}
            class={["tab", @active_tab == key && "tab-active"]}
          >
            {label}
          </.link>
        </nav>

        <section
          :if={@active_tab == :conversation}
          id="session-panel-conversation"
          role="tabpanel"
          aria-labelledby="session-tab-conversation"
          class="max-w-3xl space-y-4"
        >
          <div
            :if={@latest_request}
            id="session-latest-request"
            class="rounded-lg border border-base-300 bg-base-200/40 px-3 py-2"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <div class="text-xs font-medium opacity-60">Latest observed request</div>
                <div class="mt-0.5 font-mono text-xs">{@latest_request.chain}</div>
              </div>
              <.link patch={tab_path(@route_id, :activity, @privacy)} class="btn btn-ghost btn-xs">
                Full activity <.icon name="hero-arrow-right" class="size-3.5" />
              </.link>
            </div>
          </div>

          <.panel id="session-conversation-panel" title="Conversation">
            <p class="text-xs opacity-50 mb-3">
              The clean user ↔ agent thread saved to the database. It survives agent restarts,
              but it is not the model's complete in-memory context.
            </p>
            <.transcript transcript={@transcript} privacy={@privacy} />
          </.panel>
        </section>

        <section
          :if={@active_tab == :context}
          id="session-panel-context"
          role="tabpanel"
          aria-labelledby="session-tab-context"
          class="space-y-4"
        >
          <.context_summary evidence={@evidence} route_id={@route_id} privacy={@privacy} />
          <.compaction_detail compaction={@evidence.compaction} privacy={@privacy} />
          <.prompt_skills skills={@skills} />
          <.context_limitations evidence={@evidence} privacy={@privacy} />
        </section>

        <section
          :if={@active_tab == :activity}
          id="session-panel-activity"
          role="tabpanel"
          aria-labelledby="session-tab-activity"
          class="grid gap-4 lg:grid-cols-2 lg:items-start"
        >
          <.panel id="session-requests" title="Requests">
            <:meta><span class="font-mono">event feed</span></:meta>
            <p class="text-xs opacity-50 mb-3">
              Request lifecycle facts recorded by the display-event feed. They are not
              correlated to transcript messages without a shared identifier.
            </p>
            <.requests requests={@requests} since={@requests_since} />
          </.panel>

          <.panel id="session-agent-activity" title="Agent activity">
            <:meta>
              <span class="inline-flex items-center gap-1.5">
                <span class="signal-dot"></span> current slot
              </span>
            </:meta>
            <p class="text-xs opacity-50 mb-3">
              Parsed working log from the currently leased slot: messages, tools, results and
              system markers. <strong>Ephemeral</strong>: unavailable after slot recycling.
            </p>
            <.activity_timeline
              activity={@activity}
              rows={@activity_rows}
              privacy={@privacy}
            />
          </.panel>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :atom, default: :neutral

  defp status_fact(assigns) do
    ~H"""
    <div id={@id} class={["rounded-lg border px-3 py-2", status_tone(@tone)]}>
      <div class="text-[0.68rem] uppercase tracking-wide opacity-50">{@label}</div>
      <div class="mt-0.5 text-sm font-medium">{@value}</div>
    </div>
    """
  end

  attr :evidence, :map, required: true
  attr :route_id, :string, required: true
  attr :privacy, :boolean, required: true

  defp context_summary(assigns) do
    ~H"""
    <.panel id="session-context-summary" title="Context evidence">
      <p class="text-sm opacity-70">
        {evidence_description(@evidence.availability)} This view inventories existing evidence;
        it does not reconstruct or record an LLM request.
      </p>

      <div :if={evidence_hidden?(@evidence)} class="mt-3">
        <.sensitive_reveal />
      </div>
      <div :if={!evidence_hidden?(@evidence) && evidence_revealed?(@evidence)} class="mt-2 text-right">
        <button
          type="button"
          phx-click="transcripts_hide"
          class="btn btn-ghost btn-xs gap-1 opacity-60"
        >
          <.icon name="hero-eye-slash" class="size-3.5" /> hide sensitive evidence
        </button>
      </div>

      <div id="session-context-components" class="mt-4 grid gap-2 sm:grid-cols-3">
        <div class="rounded-lg bg-base-200/60 p-3">
          <div class="text-xs opacity-50">Durable conversation</div>
          <div class="mt-1 text-lg font-semibold">{turn_count_label(@evidence.turns)}</div>
          <div class="mt-1 text-xs opacity-50">Not the complete model context</div>
          <.link
            patch={tab_path(@route_id, :conversation, @privacy)}
            class="link link-hover mt-2 inline-block text-xs"
          >
            View conversation
          </.link>
        </div>

        <div class="rounded-lg bg-base-200/60 p-3">
          <div class="text-xs opacity-50">Current skill files</div>
          <div class="mt-1 text-lg font-semibold">{skill_count_label(@evidence.skills)}</div>
          <div class="mt-1 text-xs opacity-50">
            {skill_detail_label(@evidence.skills)}
          </div>
        </div>

        <div class="rounded-lg bg-base-200/60 p-3">
          <div class="text-xs opacity-50">Current-slot log</div>
          <div class="mt-1 text-lg font-semibold">{activity_count_label(@evidence.activity)}</div>
          <div class="mt-1 text-xs opacity-50">Ephemeral working evidence</div>
          <.link
            patch={tab_path(@route_id, :activity, @privacy)}
            class="link link-hover mt-2 inline-block text-xs"
          >
            View activity
          </.link>
        </div>
      </div>
    </.panel>
    """
  end

  attr :compaction, :map, required: true
  attr :privacy, :boolean, required: true

  defp compaction_detail(assigns) do
    ~H"""
    <.panel id="session-compaction-detail" title="Compaction">
      <%= case @compaction.state do %>
        <% state when state in [:applied, :skipped, :rejected, :failed] -> %>
          <div class="flex flex-wrap items-center gap-2">
            <span class={["badge", compaction_state_badge_class(state)]}>
              {compaction_state_label(state)}
            </span>
            <span :if={@compaction.at} class="font-mono text-xs opacity-60">{@compaction.at}</span>
            <span
              :if={is_integer(@compaction[:source_record_index])}
              class="font-mono text-xs opacity-40"
            >
              source record {@compaction.source_record_index}
            </span>
            <span :if={state == :applied} class="text-xs opacity-60">
              {@compaction.before_messages}→{@compaction.after_messages} messages · {@compaction.before_bytes}→{@compaction.after_bytes} B
            </span>
            <code :if={@compaction[:reason]} class="text-xs opacity-60">
              reason: {@compaction.reason}
            </code>
          </div>
          <p class="mt-2 text-sm opacity-70">{compaction_state_description(state)}</p>
          <p
            :if={state == :applied && @compaction.summary_available}
            class="mt-2 text-sm opacity-70"
          >
            <%= if @privacy do %>
              A matching applied-memory entry is available in Activity, with its body masked by
              privacy mode.
            <% else %>
              The exact applied memory is available as a sensitive entry in Activity.
            <% end %>
          </p>
        <% :not_observed -> %>
          <span class="badge badge-ghost">No compaction event observed</span>
          <p class="mt-2 text-sm opacity-70">
            No valid lean compaction event appears in the available current-slot log. Malformed,
            legacy, and future event shapes are not outcome evidence. This does not prove that
            compaction never happened.
          </p>
        <% :hidden -> %>
          <span class="badge badge-ghost">Reveal to check</span>
          <p class="mt-2 text-sm opacity-70">
            The sensitive current-slot log has not been fetched. Reveal sensitive evidence to
            check it for compaction evidence.
          </p>
        <% _ -> %>
          <span class="badge badge-ghost">Unknown</span>
          <p class="mt-2 text-sm opacity-70">
            Compaction status requires the revealed log from the session's currently leased slot.
          </p>
      <% end %>
    </.panel>
    """
  end

  attr :evidence, :map, required: true
  attr :privacy, :boolean, required: true

  defp context_limitations(assigns) do
    ~H"""
    <.panel id="session-context-limitations" title="What this page cannot see">
      <ul class="list-disc space-y-1 pl-5 text-sm opacity-70">
        <li>The base SubZeroClaw prompt is not exposed by the existing dashboard API.</li>
        <li>The exact in-memory message array and ordering are unavailable.</li>
        <li :if={@evidence.compaction.state == :applied && @evidence.compaction.summary_available}>
          <%= if @privacy do %>
            A matching applied summary exists in sensitive Activity, but its body is masked by
            privacy mode. This still does not expose the complete in-memory request sent to the
            model.
          <% else %>
            The exact applied summary is visible in sensitive Activity; this still does not expose
            the complete in-memory request sent to the model.
          <% end %>
        </li>
        <li :if={@evidence.compaction.state == :applied && !@evidence.compaction.summary_available}>
          This applied event has no parser-matched sensitive summary record available.
        </li>
        <li :if={@evidence.compaction.state in [:skipped, :rejected, :failed]}>
          This is a non-applied outcome; no summary is presented as applied memory.
        </li>
        <li :if={@evidence.compaction.state not in [:applied, :skipped, :rejected, :failed]}>
          Compaction-summary text is unavailable from the current evidence.
        </li>
        <li>Tool definitions and exact per-request configuration are unavailable.</li>
        <li>Pool-fallback skills are current files, not historical session evidence.</li>
      </ul>
    </.panel>
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
    <.panel
      id="session-current-skills"
      title="Current skill files"
      class="border-l-4 border-accent bg-accent/10"
    >
      <p class="text-xs opacity-50 mb-2">
        Current Markdown files read from the agent skills directory. These are context
        components, not a recorded historical prompt.
      </p>
      <p :if={@source == "slot"} class="text-xs opacity-50 mb-2">
        Read from this session's currently leased agent.
      </p>
      <p :if={@source == "pool"} class="text-xs opacity-50 mb-2">
        This session is not currently leased. These are current files from another live
        pool agent, not evidence of the files used by this session historically.
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
    <.panel id="session-current-skills" title="Current skill files">
      <div class="text-sm opacity-60">loading…</div>
    </.panel>
    """
  end

  # No live agent anywhere to read skills from (swarm down / pool empty) — say so
  # rather than render an empty standout card.
  defp prompt_skills(assigns) do
    ~H"""
    <.panel id="session-current-skills" title="Current skill files">
      <div class="text-sm opacity-60">
        Unavailable (no live agent to read current skill files from).
      </div>
    </.panel>
    """
  end

  attr :transcript, :any, required: true
  attr :privacy, :boolean, default: false

  defp transcript(%{transcript: {:ok, %{"turns" => turns, "source" => source}}} = assigns)
       when turns != [] do
    assigns = assign(assigns, turns: turns, source: source)

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <span class="text-xs opacity-60">
        {if @source == "store",
          do: "saved to the database · survives restarts",
          else: "source: #{@source}"}
      </span>
      <button type="button" phx-click="transcripts_hide" class="btn btn-ghost btn-xs gap-1 opacity-60">
        <.icon name="hero-eye-slash" class="size-3.5" /> hide
      </button>
    </div>
    <.conversation id="session-conversation" turns={@turns} privacy={@privacy} />
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

  defp display_session_id(nil, _privacy?), do: nil
  defp display_session_id(sid, false), do: sid

  defp display_session_id(sid, true) when is_binary(sid) do
    case PrivacyRedactor.mask_cid(sid) do
      ^sid -> "•••"
      masked -> masked
    end
  end

  defp tab("context"), do: :context
  defp tab("activity"), do: :activity
  defp tab(_), do: :conversation

  defp session_tabs,
    do: [conversation: "Conversation", context: "Context evidence", activity: "Activity"]

  # Privacy mode must not copy a raw/encoded session id into tab hrefs. Query-only
  # patches stay on the current LiveView route; normal mode keeps canonical URLs.
  defp tab_path(_route_id, tab, true), do: "?tab=#{tab}"
  defp tab_path(route_id, tab, false), do: "/sessions/#{route_id}?tab=#{tab}"

  defp latest_request([request | _]), do: request
  defp latest_request(_), do: nil

  defp request_status(nil), do: "No request observed"

  defp request_status(%{status: status, stalled: stalled}) do
    cond do
      status == "abandoned" -> "Abandoned"
      status == "replied" and stalled -> "Replied after stall"
      status == "replied" -> "Replied"
      stalled -> "Stalled"
      true -> "Awaiting reply"
    end
  end

  defp request_tone_name(nil), do: :neutral
  defp request_tone_name(%{status: "abandoned"}), do: :warning
  defp request_tone_name(%{stalled: true}), do: :warning
  defp request_tone_name(%{status: "replied"}), do: :success
  defp request_tone_name(_request), do: :info

  defp evidence_label(:live_slot), do: "Live slot evidence"
  defp evidence_label(:sensitive_hidden), do: "Reveal to inspect"
  defp evidence_label(:components_only), do: "Components only"
  defp evidence_label(_), do: "Unavailable"

  defp evidence_description(:live_slot),
    do: "A parsed log is available from this session's currently leased slot."

  defp evidence_description(:sensitive_hidden),
    do:
      "Sensitive transcript and current-slot evidence have not been fetched. Reveal them to inspect what is available."

  defp evidence_description(:components_only),
    do: "Durable or current-file components are available, but no live slot log is."

  defp evidence_description(_), do: "No conversation-context evidence is currently available."

  defp evidence_tone(:live_slot), do: :success
  defp evidence_tone(:sensitive_hidden), do: :neutral
  defp evidence_tone(:components_only), do: :info
  defp evidence_tone(_), do: :neutral

  defp compaction_label(:applied), do: "Applied"
  defp compaction_label(:skipped), do: "Skipped"
  defp compaction_label(:rejected), do: "Rejected"
  defp compaction_label(:failed), do: "Failed"
  defp compaction_label(:not_observed), do: "No event observed"
  defp compaction_label(:hidden), do: "Reveal to check"
  defp compaction_label(_), do: "Unknown"

  defp compaction_tone(:rejected), do: :warning
  defp compaction_tone(:failed), do: :warning
  defp compaction_tone(:not_observed), do: :neutral
  defp compaction_tone(_), do: :neutral

  defp compaction_state_label(:applied), do: "Applied"
  defp compaction_state_label(:skipped), do: "Skipped"
  defp compaction_state_label(:rejected), do: "Rejected"
  defp compaction_state_label(:failed), do: "Failed"

  defp compaction_state_badge_class(:applied), do: "badge-neutral badge-outline"
  defp compaction_state_badge_class(:skipped), do: "badge-ghost"
  defp compaction_state_badge_class(:rejected), do: "badge-warning"
  defp compaction_state_badge_class(:failed), do: "badge-error badge-outline"

  defp compaction_state_description(:applied),
    do: "The latest valid lean event records an applied outcome."

  defp compaction_state_description(:skipped),
    do: "The latest valid lean event records that compaction was skipped."

  defp compaction_state_description(:rejected),
    do: "The latest valid lean event records that compaction was rejected."

  defp compaction_state_description(:failed),
    do: "The latest valid lean event records that compaction failed."

  defp last_activity_label(%{"last_activity" => last_activity}), do: relative_time(last_activity)
  defp last_activity_label(_), do: "—"

  defp status_tone(:success), do: "border-success/30 bg-success/5"
  defp status_tone(:warning), do: "border-warning/40 bg-warning/5"
  defp status_tone(:info), do: "border-info/30 bg-info/5"
  defp status_tone(_), do: "border-base-300 bg-base-200/30"

  defp turn_count_label(%{state: state, count: count}) when state in [:available, :empty],
    do: "#{count} turns"

  defp turn_count_label(%{state: :hidden}), do: "Hidden"
  defp turn_count_label(%{state: :loading}), do: "Loading"
  defp turn_count_label(_), do: "Unavailable"

  defp activity_count_label(%{state: :slot, count: count}), do: "#{count} entries"
  defp activity_count_label(%{state: :hidden}), do: "Hidden"
  defp activity_count_label(%{state: :loading}), do: "Loading"
  defp activity_count_label(_), do: "Unavailable"

  defp skill_source_label(:slot), do: "leased slot"
  defp skill_source_label(:pool), do: "pool fallback"
  defp skill_source_label(:loading), do: "loading"
  defp skill_source_label(_), do: "unavailable"

  defp skill_count_label(%{state: state, count: count})
       when state in [:slot, :pool, :available, :empty],
       do: to_string(count)

  defp skill_count_label(%{state: :loading}), do: "Loading"
  defp skill_count_label(_), do: "Unavailable"

  defp skill_detail_label(%{state: state} = skills)
       when state in [:slot, :pool, :available, :empty],
       do: "#{format_bytes(skills.bytes)} · #{skill_source_label(state)}"

  defp skill_detail_label(%{state: :loading}), do: "Waiting for current files"
  defp skill_detail_label(_), do: "No current skill source"

  defp evidence_hidden?(evidence),
    do: evidence.turns.state == :hidden or evidence.activity.state == :hidden

  defp evidence_revealed?(evidence),
    do: evidence.turns.state in [:available, :empty] or evidence.activity.state == :slot

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "0 B"

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
      done: ep.done,
      status: ep.status,
      queued: ep.count - 1,
      chain: chain(ep, claim)
    }
  end

  defp request_state_changed?(:loading, _summary, _cid), do: false

  defp request_state_changed?(requests, summary, cid)
       when is_list(requests) and is_map(summary) do
    latest = List.first(requests)
    in_flight = Enum.find(summary[:in_flight] || [], &(&1[:cid] == cid))

    cond do
      in_flight == nil -> latest != nil and latest.done == false
      latest == nil -> true
      latest.done -> true
      latest.opened_at != in_flight[:opened_at] -> true
      latest.stalled != in_flight[:stalled] -> true
      latest.queued != max((in_flight[:count] || 1) - 1, 0) -> true
      true -> false
    end
  end

  defp request_state_changed?(_requests, _summary, _cid), do: false

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
        ep.status == "replied" -> "✓ replied #{duration(ep.duration)}"
        ep.status == "abandoned" -> "✖ abandoned — no reply"
        ep.done -> "closed (#{ep.status || "unknown"})"
        ep.stalled -> "⚠ stalled — no reply"
        true -> "… awaiting reply"
      end

    ["open", claim_leg, feedback_leg, verdict_leg]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" → ")
  end

  attr :requests, :any, required: true
  attr :since, :any, default: nil

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
      (requests observed since <.local_time id="requests-since" ts={@since} />)
    </p>
    """
  end

  defp requests(assigns) do
    ~H"""
    <div id="session-requests-empty">
      <.empty_state msg="No requests observed for this conversation" />
      <p class="text-xs opacity-40 mt-2">
        (requests observed since <.local_time id="requests-since-empty" ts={@since} />).
      </p>
    </div>
    """
  end

  # A restored story can legitimately contain episodes older than the feed
  # process's latest baseline (for example after a dashboard restart). Never
  # print a "since" time later than rows visible immediately above it.
  defp requests_since([_ | _] = requests, story) do
    oldest_request =
      requests
      |> Enum.map(& &1.opened_at)
      |> Enum.filter(&is_number/1)
      |> Enum.min(fn -> nil end)

    [oldest_request, story_baseline(story)]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp requests_since(_requests, story), do: story_baseline(story)

  defp story_baseline(%{baseline_at: %DateTime{} = baseline}), do: DateTime.to_unix(baseline)
  defp story_baseline(%{baseline_at: baseline}) when is_number(baseline), do: baseline
  defp story_baseline(_story), do: nil

  # the verdict leg keys the row's left accent — the same scan-by-color grammar
  # as the Events story rows (success = replied, warning = stalled, primary = open)
  defp request_tone(%{chain: chain} = r) do
    cond do
      r.status == "abandoned" or r.stalled -> "border-warning/70"
      String.contains?(chain, "✓ replied") -> "border-success/60"
      true -> "border-primary/50"
    end
  end
end
