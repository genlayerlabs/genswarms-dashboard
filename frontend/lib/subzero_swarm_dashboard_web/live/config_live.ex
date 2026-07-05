defmodule SubzeroSwarmDashboardWeb.ConfigLive do
  @moduledoc """
  The swarm's effective object configuration.

  READ (always): rows come from the dashboard backend, already redacted
  against each package's `config_schema` (gsp design §14.2.1) — this page
  renders them as-is and never receives secret values.

  WRITE (fail-closed, off by default): only when `CONFIGURATOR_ENGINE_URL`
  is set do `x-mutable` rows grow an edit affordance. Edits go to the
  genswarms ENGINE (`PATCH .../objects/:name/config`), whose config_schema
  op gate is the authority — this UI merely refuses earlier what the engine
  would refuse anyway. Every applied change lands in the overlay log,
  rendered below as the audit trail.
  """
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.{EngineClient, SwarmClient}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load)

    {:ok,
     assign(socket,
       page_title: "Config",
       objects: :loading,
       error: nil,
       configurator?: EngineClient.enabled?(),
       editing: nil,
       edit_error: nil,
       overlay: []
     )}
  end

  @impl true
  def handle_info(:load, socket) do
    socket =
      case SwarmClient.config(socket.assigns.swarm) do
        {:ok, %{"objects" => objects}} -> assign(socket, objects: objects, error: nil)
        {:error, reason} -> assign(socket, objects: [], error: inspect(reason))
      end

    {:noreply, load_overlay(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("edit", %{"object" => obj, "key" => key, "value" => value}, socket) do
    {:noreply, assign(socket, editing: %{object: obj, key: key, draft: value}, edit_error: nil)}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing: nil, edit_error: nil)}

  def handle_event("save_edit", %{"draft" => draft}, socket) do
    %{object: obj, key: key} = socket.assigns.editing

    with {:ok, value} <- parse_draft(draft),
         {:ok, _} <- EngineClient.patch_object_config(socket.assigns.swarm, obj, %{key => value}) do
      send(self(), :load)

      {:noreply,
       socket
       |> assign(editing: nil, edit_error: nil)
       |> put_flash(:info, "#{obj}.#{key} updated — object restarted with the merged config")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, edit_error: format_reason(reason))}
    end
  end

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
          <span :if={@configurator?} class="badge badge-warning badge-sm align-middle ml-2" title="CONFIGURATOR_ENGINE_URL is set — x-mutable fields are editable">
            write enabled
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
              title="package ships no config_schema — values elided, nothing editable (fail-closed)"
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
                  <%= if editing?(@editing, obj["name"], row["key"]) do %>
                    <form phx-submit="save_edit" class="space-y-2">
                      <textarea
                        name="draft"
                        rows="4"
                        class="textarea textarea-bordered textarea-sm w-full font-mono"
                      >{@editing.draft}</textarea>
                      <div :if={@edit_error} class="text-error text-xs">{@edit_error}</div>
                      <div class="flex gap-2">
                        <button type="submit" class="btn btn-primary btn-xs">apply</button>
                        <button type="button" class="btn btn-ghost btn-xs" phx-click="cancel_edit">
                          cancel
                        </button>
                        <span class="text-xs opacity-50 self-center">
                          JSON value · object restarts on apply · logged in the overlay
                        </span>
                      </div>
                    </form>
                  <% else %>
                    <%= if row["value"] == nil do %>
                      <span class="opacity-40" title={elided_title(row)}>•••</span>
                    <% else %>
                      {format_value(row["value"])}
                    <% end %>
                    <button
                      :if={@configurator? and row["mutable"]}
                      class="btn btn-ghost btn-xs ml-2 align-top"
                      phx-click="edit"
                      phx-value-object={obj["name"]}
                      phx-value-key={row["key"]}
                      phx-value-value={draft_for(row["value"])}
                    >
                      edit
                    </button>
                  <% end %>
                </td>
                <td class="align-top text-xs opacity-50 font-sans max-w-xs">
                  {row["description"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@configurator? and @overlay != []} class="rounded-box border border-base-300 bg-base-200/60">
          <div class="px-4 py-2.5 border-b border-base-300 text-sm font-semibold">
            Overlay — mutation audit trail
          </div>
          <ul class="p-4 space-y-1 text-xs font-mono">
            <li :for={ev <- @overlay}>
              <span class="badge badge-ghost badge-xs mr-1">{ev["op"]}</span>
              {Jason.encode!(ev["payload"] || %{})}
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp load_overlay(socket) do
    if socket.assigns.configurator? do
      case EngineClient.overlay(socket.assigns.swarm) do
        {:ok, %{"events" => events}} -> assign(socket, overlay: events)
        _ -> socket
      end
    else
      socket
    end
  end

  defp editing?(%{object: o, key: k}, o, k), do: true
  defp editing?(_, _, _), do: false

  # a bare string draft is accepted as a string; anything else must be JSON
  defp parse_draft(draft) do
    case Jason.decode(draft) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:ok, String.trim(draft)}
    end
  end

  defp format_reason({422, %{"error" => e}}), do: "rejected by the op gate: #{e}"
  defp format_reason({status, body}), do: "engine #{status}: #{inspect(body)}"
  defp format_reason(:configurator_disabled), do: "configurator disabled"
  defp format_reason(other), do: inspect(other)

  defp draft_for(nil), do: ""
  defp draft_for(v) when is_binary(v), do: v
  defp draft_for(v), do: Jason.encode!(v)

  defp obj_list(:loading), do: []
  defp obj_list(objects) when is_list(objects), do: objects
  defp obj_list(_), do: []

  defp elided_title(%{"in_schema" => false}), do: "not in the package's config_schema (fail-closed)"
  defp elided_title(%{"secret" => true}), do: "x-secret — never shown"
  defp elided_title(_), do: "elided"

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: Jason.encode!(v, pretty: true)
end
