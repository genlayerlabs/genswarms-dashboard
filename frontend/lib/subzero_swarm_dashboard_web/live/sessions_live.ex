defmodule SubzeroSwarmDashboardWeb.SessionsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  # Reply-health thresholds: a conversation whose last inbound has gone this long
  # with no outbound delivery is flagged "no reply"; the skew absorbs clock drift
  # between ingress (inbound) and the sender (outbound).
  @reply_grace_s 120
  @reply_skew_s 5

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Sessions", q: "")}

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    sessions = filter(assigns[:snapshot], assigns.q)
    now = System.os_time(:second)
    deliveries = deliveries(assigns[:snapshot])

    assigns =
      assign(assigns,
        sessions: sessions,
        live_count: Enum.count(sessions, &(&1["state"] == "active")),
        deliveries: deliveries,
        now: now,
        unanswered: Enum.count(sessions, &(reply_status(&1, deliveries, now) == :unanswered)),
        issues_by_cid: story_issues(assigns.story),
        audience: audience(assigns[:snapshot])
      )

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
      <div class="space-y-5">
        <h1 class="text-2xl">Sessions</h1>

        <%!-- one toolbar: search left, the reply-health alarm anchored right --%>
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
          <span
            :if={@snapshot && @unanswered > 0}
            class="badge badge-warning badge-sm gap-1 ml-auto"
            title="conversations that received a message but got no reply"
          >
            ⚠ {@unanswered} unanswered
          </span>
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
                  <th>Reply</th>
                  <th>Issues</th>
                  <th>Agent</th>
                  <th>Last seen</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={s <- @sessions}
                  class="row-press"
                  phx-click="inspect"
                  phx-value-session_id={s["session_id"]}
                >
                  <td>
                    <.identity user={s["user"]} session_id={s["session_id"]} label={s["label"]} />
                  </td>
                  <td><.live_dot state={s["state"]} label /></td>
                  <td><.reply_badge status={reply_status(s, @deliveries, @now)} /></td>
                  <td>
                    <.issue_badge
                      sid={s["session_id"]}
                      issues={@issues_by_cid[s["session_id"]] || []}
                    />
                  </td>
                  <td class="font-mono text-xs opacity-70">{s["agent"]}</td>
                  <td class="text-sm opacity-70 tnum whitespace-nowrap">
                    {relative_time(s["last_activity"])}
                  </td>
                  <td class="text-right">
                    <.link
                      navigate={~p"/sessions/#{Base.url_encode64(s["session_id"], padding: false)}"}
                      class="btn btn-ghost btn-xs btn-circle"
                      onclick="event.stopPropagation()"
                      title="Open full session"
                    >
                      <.icon name="hero-arrow-up-right" class="size-4 opacity-60" />
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </.panel>

        <.panel :if={consumers(@snapshot)} title="Consumers">
          <:meta>
            <span class="font-mono tnum">{consumers(@snapshot)["count"]}</span>
          </:meta>
          <table class="table table-xs">
            <tbody>
              <tr :for={c <- consumers(@snapshot)["items"] || []}>
                <td class="font-mono text-xs">{c["session_id"]}</td>
                <td>{c["mode"]}</td>
                <td class="opacity-60">{if c["opt_out"], do: "opted out"}</td>
              </tr>
            </tbody>
          </table>
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

  defp consumers(nil), do: nil
  defp consumers(snap), do: get_in(snap, ["extensions", "consumers"])

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

  # ── reply-delivery health ───────────────────────────────────────────────────
  # cid => latest delivery (%{"at", "status"}), from the sender's dashboard extension.
  defp deliveries(nil), do: %{}

  defp deliveries(snap) do
    (get_in(snap, ["extensions", "deliveries", "items"]) || [])
    |> Map.new(fn d -> {d["session_id"], d} end)
  end

  @doc """
  Did we answer the last inbound? Compares ingress's `last_activity` (inbound)
  with the sender's last delivery (outbound) for this conversation. ALL times are
  unix SECONDS: `now` and the delivery `at` are `System.os_time(:second)`-scale,
  and `last_activity` is an ISO8601 string parsed with `to_unix/1`. Keeping every
  side in seconds is the contract this guards. Public for unit tests.
  """
  def reply_status(session, deliveries, now) do
    last_in = to_unix(session["last_activity"])
    last_send = (deliveries[session["session_id"]] || %{})["at"]

    cond do
      is_nil(last_in) -> :idle
      is_integer(last_send) and last_send >= last_in - @reply_skew_s -> :answered
      now - last_in <= @reply_grace_s -> :pending
      true -> :unanswered
    end
  end

  defp to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp to_unix(_), do: nil

  attr :status, :atom, required: true

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
      class="badge badge-warning badge-xs"
      title="received a message but never replied"
    >
      ⚠ no reply
    </span>
    <span :if={@status == :idle} class="opacity-40 text-xs">—</span>
    """
  end

  attr :sid, :string, required: true
  attr :issues, :list, default: []

  # Event-derived trouble for this conversation (delivery failures, inbox_full,
  # stalled, …) within the issues window. The id is url-safe-base64 of the cid —
  # same encoding the row's deep-link uses — because cids contain colons. Deep-links
  # to the cid-filtered issues-only Events story view (spec §5.6), like Overview.
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

  defp issue_badge(assigns) do
    ~H"""
    <span class="opacity-40 text-xs">—</span>
    """
  end
end
