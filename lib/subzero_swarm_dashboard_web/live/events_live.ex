defmodule SubzeroSwarmDashboardWeb.EventsLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Events",
        events: :loading,
        # server-side filters
        level: "",
        category: "",
        agent: "",
        minutes: "",
        # client-side text search over the message
        contains: "",
        timer: nil
      )

    if connected?(socket), do: send(self(), :load)
    {:ok, socket}
  end

  @impl true
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
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Single recurring refresh: cancel any pending timer, fetch with the server-side
  # filters, reschedule exactly one.
  defp reload(socket) do
    if ref = socket.assigns[:timer], do: Process.cancel_timer(ref)
    timer = Process.send_after(self(), :load, @refresh_ms)
    assign(socket, events: SwarmClient.events(socket.assigns.swarm, server_opts(socket.assigns)), timer: timer)
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
    ~H"""
    <Layouts.app flash={@flash} active={:events} swarm={@swarm} inspect={@inspect} inspect_transcript={@inspect_transcript} inspect_activity={@inspect_activity}>
      <div class="space-y-5">
        <h1 class="text-2xl">
          Events <span class="text-xs opacity-50 font-sans align-middle">structured lifecycle facts</span>
        </h1>

        <form phx-change="filter" class="flex flex-wrap gap-2 items-center text-sm">
          <select name="level" class="select select-bordered select-sm">
            <option value="" selected={@level == ""}>all levels</option>
            <option :for={l <- ~w(error warning info debug)} value={l} selected={@level == l}>{l}</option>
          </select>
          <select name="category" class="select select-bordered select-sm">
            <option value="" selected={@category == ""}>all categories</option>
            <option :for={c <- ~w(swarm agent object router system)} value={c} selected={@category == c}>{c}</option>
          </select>
          <input type="text" name="agent" value={@agent} placeholder="agent" class="input input-bordered input-sm w-28" />
          <select name="minutes" class="select select-bordered select-sm">
            <option value="" selected={@minutes == ""}>all time</option>
            <option :for={{m, lbl} <- [{"5", "5m"}, {"60", "1h"}, {"1440", "24h"}]} value={m} selected={@minutes == m}>{lbl}</option>
          </select>
          <input type="text" name="contains" value={@contains} placeholder="contains text" class="input input-bordered input-sm w-40" />
        </form>

        <.event_table events={@events} contains={@contains} />
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
        <tr><th>time</th><th>level</th><th>category</th><th>agent</th><th>message</th></tr>
      </thead>
      <tbody>
        <tr :for={e <- @events}>
          <td class="text-xs opacity-60 whitespace-nowrap">{e["timestamp"]}</td>
          <td><span class={["badge badge-xs", level_class(e["level"])]}>{e["level"]}</span></td>
          <td class="text-xs">{e["category"]}</td>
          <td class="font-mono text-xs">{e["agent"]}</td>
          <td class="text-xs">{e["message"]}</td>
        </tr>
        <tr :if={@events == []}><td colspan="5" class="opacity-60">No events match.</td></tr>
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
end
