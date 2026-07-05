defmodule SubzeroSwarmDashboardWeb.ConfigLive do
  @moduledoc """
  Read-only view of the swarm's effective object configuration, as redacted
  by the backend against each package's `config_schema` (gsp design §14.2.1).
  The redaction happens server-side (backend) — this page renders rows as-is
  and NEVER receives secret values: `x-secret` values arrive already elided
  (except `*_env` fields, whose value is an env var name by contract).
  """
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.SwarmClient

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load)
    {:ok, assign(socket, page_title: "Config", objects: :loading, error: nil)}
  end

  @impl true
  def handle_info(:load, socket) do
    case SwarmClient.config(socket.assigns.swarm) do
      {:ok, %{"objects" => objects}} ->
        {:noreply, assign(socket, objects: objects, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, objects: [], error: inspect(reason))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:config}
      swarm={@swarm}
      snapshot={@snapshot}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5 max-w-4xl">
        <h1 class="text-2xl">
          Config
          <span class="text-xs opacity-50 font-sans align-middle">
            effective object config (seed ⊕ overlay) · redacted per config_schema
          </span>
        </h1>

        <div :if={@error} class="alert alert-warning text-sm">
          config unavailable: {@error}
        </div>

        <div :if={@objects == :loading} class="opacity-50 text-sm">loading…</div>

        <div :for={obj <- obj_list(@objects)} class="rounded-box border border-base-300 bg-base-200/60">
          <div class="flex items-center gap-2 px-4 py-2.5 border-b border-base-300">
            <span class="font-mono font-semibold">{obj["name"]}</span>
            <span class="text-xs opacity-50 font-mono">{obj["handler"]}</span>
            <span
              :if={!obj["has_schema"]}
              class="ml-auto badge badge-ghost badge-sm"
              title="package ships no config_schema — values elided (fail-closed)"
            >
              no schema
            </span>
          </div>

          <table class="table table-sm font-mono">
            <tbody>
              <tr :for={row <- obj["config"]}>
                <td class="w-56 align-top">
                  {row["key"]}
                  <span :if={row["mutable"]} class="badge badge-info badge-xs ml-1" title="hot-editable via update_config">
                    mutable
                  </span>
                  <span :if={row["secret"]} class="badge badge-warning badge-xs ml-1" title="x-secret: value is an env var name; secret never leaves the object">
                    secret
                  </span>
                </td>
                <td class="align-top whitespace-pre-wrap break-all">
                  <%= if row["value"] == nil do %>
                    <span class="opacity-40" title={elided_title(row)}>•••</span>
                  <% else %>
                    {format_value(row["value"])}
                  <% end %>
                </td>
                <td class="align-top text-xs opacity-50 font-sans max-w-xs">
                  {row["description"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp obj_list(:loading), do: []
  defp obj_list(objects) when is_list(objects), do: objects
  defp obj_list(_), do: []

  defp elided_title(%{"in_schema" => false}), do: "not in the package's config_schema (fail-closed)"
  defp elided_title(%{"secret" => true}), do: "x-secret — never shown"
  defp elided_title(_), do: "elided"

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: Jason.encode!(v, pretty: true)
end
