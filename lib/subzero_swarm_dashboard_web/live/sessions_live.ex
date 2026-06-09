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
        unanswered: Enum.count(sessions, &(reply_status(&1, deliveries, now) == :unanswered))
      )

    ~H"""
    <Layouts.app flash={@flash} active={:sessions} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript} inspect_activity={@inspect_activity}>
      <div class="space-y-5">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div class="flex items-baseline gap-3">
            <h1 class="text-2xl">Sessions</h1>
            <span :if={@snapshot} class="text-sm opacity-60 tnum">
              {length(@sessions)} total · <span class="text-[var(--signal)]">{@live_count} live</span>
            </span>
            <span :if={@snapshot && @unanswered > 0} class="badge badge-warning badge-sm gap-1" title="conversations that received a message but got no reply">
              ⚠ {@unanswered} unanswered
            </span>
          </div>
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
        </div>

        <div :if={@snapshot} class="rounded-box border border-base-300 overflow-hidden">
          <table class="table">
            <thead>
              <tr class="text-xs uppercase tracking-wide">
                <th>User</th><th>State</th><th>Reply</th><th>Agent</th><th>Last seen</th><th></th>
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
                  <.identity user={s["user"]} session_id={s["session_id"]} />
                </td>
                <td><.live_dot state={s["state"]} label /></td>
                <td><.reply_badge status={reply_status(s, @deliveries, @now)} /></td>
                <td class="font-mono text-xs opacity-70">{s["agent"]}</td>
                <td class="text-sm opacity-70 tnum whitespace-nowrap">{relative_time(s["last_activity"])}</td>
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
              <tr :if={@sessions == []}>
                <td colspan="6" class="text-center opacity-55 py-8">
                  No sessions{if @q != "", do: " match \"#{@q}\""}.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={consumers(@snapshot)} class="card bg-base-200/60 border border-base-300 p-4">
          <h2 class="font-semibold mb-2 flex items-center gap-2">
            Consumers
            <span class="badge badge-ghost badge-sm tnum">{consumers(@snapshot)["count"]}</span>
          </h2>
          <table class="table table-xs">
            <tbody>
              <tr :for={c <- consumers(@snapshot)["items"] || []}>
                <td class="font-mono text-xs">{c["session_id"]}</td>
                <td>{c["mode"]}</td>
                <td class="opacity-60">{if c["opt_out"], do: "opted out"}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={is_nil(@snapshot)} class="opacity-60">Waiting for the first snapshot…</div>
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
    <span :if={@status == :answered} class="badge badge-success badge-xs" title="replied to the last message">answered</span>
    <span :if={@status == :pending} class="badge badge-ghost badge-xs" title="received — reply in flight">replying…</span>
    <span :if={@status == :unanswered} class="badge badge-warning badge-xs" title="received a message but never replied">⚠ no reply</span>
    <span :if={@status == :idle} class="opacity-40 text-xs">—</span>
    """
  end
end
