defmodule SubzeroSwarmDashboardWeb.SessionsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Sessions", q: "")}

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sessions, filter(assigns[:snapshot], assigns.q))

    ~H"""
    <Layouts.app flash={@flash} active={:sessions} swarm={@swarm}>
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4">
          <h1 class="text-xl font-semibold">Sessions</h1>
          <form phx-change="search" class="flex-1 max-w-md">
            <input
              type="text"
              name="q"
              value={@q}
              placeholder="search session_id / chat_id / user_id"
              class="input input-bordered input-sm w-full"
            />
          </form>
        </div>

        <table :if={@snapshot} class="table table-sm">
          <thead>
            <tr><th>session</th><th>transport</th><th>agent</th><th>state</th><th>last activity</th></tr>
          </thead>
          <tbody>
            <tr :for={s <- @sessions} class="hover">
              <td>
                <.link navigate={~p"/sessions/#{s["session_id"]}"} class="link link-primary font-mono text-xs">
                  {s["session_id"]}
                </.link>
                <div class="text-xs opacity-50">{ref_str(s["transport_ref"])}</div>
              </td>
              <td><span class="badge badge-ghost badge-sm">{s["transport"]}</span></td>
              <td class="font-mono text-xs">{s["agent"]}</td>
              <td>
                <span class={["badge badge-sm", s["state"] == "active" && "badge-success"]}>{s["state"]}</span>
              </td>
              <td class="text-xs opacity-70">{s["last_activity"]}</td>
            </tr>
            <tr :if={@sessions == []}><td colspan="5" class="opacity-60">No sessions{if @q != "", do: " match"}.</td></tr>
          </tbody>
        </table>

        <div :if={consumers(@snapshot)} class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Consumers ({consumers(@snapshot)["count"]})</h2>
          <table class="table table-xs">
            <tbody>
              <tr :for={c <- consumers(@snapshot)["items"] || []}>
                <td class="font-mono text-xs">{c["session_id"]}</td>
                <td>{c["mode"]}</td>
                <td>{if c["opt_out"], do: "opted out"}</td>
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
      Enum.filter(sessions, fn s ->
        String.contains?(String.downcase(s["session_id"] || ""), q) or ref_match?(s["transport_ref"], q)
      end)
    end
  end

  defp ref_match?(ref, q) when is_map(ref),
    do: ref |> Map.values() |> Enum.any?(&String.contains?(String.downcase(to_string(&1)), q))

  defp ref_match?(_, _), do: false

  defp ref_str(ref) when is_map(ref),
    do: ref |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(" ")

  defp ref_str(_), do: ""

  defp consumers(nil), do: nil
  defp consumers(snap), do: get_in(snap, ["extensions", "consumers"])
end
