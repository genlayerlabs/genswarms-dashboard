defmodule SubzeroSwarmDashboardWeb.UsageLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.RouterClient

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load)
    {:ok, assign(socket, page_title: "Usage", usage: :loading)}
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, assign(socket, usage: RouterClient.usage())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:usage} swarm={@swarm}>
      <div class="space-y-4 max-w-4xl">
        <h1 class="text-xl font-semibold">Usage <span class="text-xs opacity-50">LLM tokens / cost (router)</span></h1>
        <.usage usage={@usage} />
      </div>
    </Layouts.app>
    """
  end

  attr :usage, :any, required: true

  defp usage(%{usage: {:ok, u}} = assigns) do
    assigns = assign(assigns, totals: u["totals"] || %{}, by_model: u["by_model"] || [], by_profile: u["by_profile"] || [])

    ~H"""
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat label="Total tokens" value={@totals["total_tokens"] || 0} />
      <.stat label="Requests" value={@totals["requests"] || 0} />
      <.stat label="Errors" value={@totals["errors"] || 0} />
      <.stat label="Cost (USD)" value={@totals["cost_usd"] || "—"} />
    </div>
    <div class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">By model</h2>
      <table class="table table-xs">
        <thead><tr><th>model</th><th>provider</th><th>requests</th><th>tokens</th></tr></thead>
        <tbody>
          <tr :for={m <- @by_model}>
            <td class="font-mono text-xs">{m["served_model_id"]}</td>
            <td>{m["provider"]}</td>
            <td>{m["requests"]}</td>
            <td>{m["total_tokens"]}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp usage(%{usage: :loading} = assigns) do
    ~H"""
    <div class="opacity-60">loading…</div>
    """
  end

  defp usage(assigns) do
    ~H"""
    <div class="card bg-base-200 p-6 text-center">
      <div class="text-lg font-semibold">Usage unavailable</div>
      <div class="text-sm opacity-60 mt-1">
        The router's <code>/v1/usage</code> endpoint isn't configured or doesn't exist yet
        (set <code>ROUTER_USAGE_URL</code> + <code>ROUTER_API_KEY</code>; see spec §9).
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="text-xs uppercase opacity-60">{@label}</div>
      <div class="text-2xl font-bold">{@value}</div>
    </div>
    """
  end
end
