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

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboard.{EngineClient, SwarmClient}
  alias SubzeroSwarmDashboardWeb.DashHooks

  @identity_key_fragments ~w(chat cid conversation from handle label name session user username)

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
    privacy? = assigns[:privacy] == true

    assigns =
      assign(assigns,
        display_error: redact_string(assigns[:error], privacy?),
        display_edit_error: redact_string(assigns[:edit_error], privacy?),
        display_objects: objects_for_privacy(assigns[:objects], privacy?),
        display_overlay: overlay_for_privacy(assigns[:overlay], privacy?),
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:config}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
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
          <span
            :if={@configurator?}
            class="badge badge-warning badge-sm align-middle ml-2"
            title="CONFIGURATOR_ENGINE_URL is set — x-mutable fields are editable"
          >
            write enabled
          </span>
        </h1>

        <div :if={@display_error} class="alert alert-warning text-sm">
          config unavailable: {@display_error}
        </div>

        <div :if={@objects == :loading} class="opacity-50 text-sm">loading…</div>

        <div
          :for={obj <- obj_list(@display_objects)}
          class="rounded-box border border-base-300 bg-base-200/60"
        >
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
                  <span
                    :if={row["mutable"]}
                    class="badge badge-info badge-xs ml-1"
                    title="hot-editable via update_config"
                  >
                    mutable
                  </span>
                  <span
                    :if={row["secret"]}
                    class="badge badge-warning badge-xs ml-1"
                    title="x-secret: value is an env var name; secret never leaves the object"
                  >
                    secret
                  </span>
                </td>
                <td class="align-top whitespace-pre-wrap break-all">
                  <%= if editing?(@editing, obj["name"], row["key"]) do %>
                    <%= if @privacy do %>
                      <div class="text-xs opacity-60">Editing hidden in privacy mode.</div>
                    <% else %>
                      <form phx-submit="save_edit" class="space-y-2">
                        <textarea
                          name="draft"
                          rows="4"
                          class="textarea textarea-bordered textarea-sm w-full font-mono"
                        >{@editing.draft}</textarea>
                        <div :if={@display_edit_error} class="text-error text-xs">
                          {@display_edit_error}
                        </div>
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
                    <% end %>
                  <% else %>
                    <%= if row["value"] == nil do %>
                      <span class="opacity-40" title={elided_title(row)}>•••</span>
                    <% else %>
                      {format_value(row["value"])}
                    <% end %>
                    <button
                      :if={@configurator? and row["mutable"] and !@privacy}
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

        <div
          :if={@configurator? and @display_overlay != []}
          class="rounded-box border border-base-300 bg-base-200/60"
        >
          <div class="px-4 py-2.5 border-b border-base-300 text-sm font-semibold">
            Overlay — mutation audit trail
          </div>
          <ul class="p-4 space-y-1 text-xs font-mono">
            <li :for={ev <- @display_overlay}>
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

  defp elided_title(%{"in_schema" => false}),
    do: "not in the package's config_schema (fail-closed)"

  defp elided_title(%{"secret" => true}), do: "x-secret — never shown"
  defp elided_title(_), do: "elided"

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: Jason.encode!(v, pretty: true)

  defp objects_for_privacy(objects, false), do: objects
  defp objects_for_privacy(:loading, _privacy?), do: :loading

  defp objects_for_privacy(objects, true) when is_list(objects),
    do: Enum.map(objects, &object_for_privacy/1)

  defp objects_for_privacy(objects, _privacy?), do: objects

  defp object_for_privacy(%{} = obj) do
    Map.update(obj, "config", [], fn rows ->
      Enum.map(rows || [], &row_for_privacy/1)
    end)
  end

  defp object_for_privacy(obj), do: obj

  defp row_for_privacy(%{} = row) do
    row
    |> Map.update("key", nil, &PrivacyRedactor.mask_cid/1)
    |> Map.update("description", nil, &PrivacyRedactor.mask_cid/1)
    |> Map.update("value", nil, &redact_config_value(row["key"], &1))
  end

  defp row_for_privacy(row), do: row

  defp redact_config_value(_key, nil), do: nil

  defp redact_config_value(key, value) do
    value =
      %{to_string(key) => value}
      |> PrivacyRedactor.mask_identity()
      |> Map.get(to_string(key))

    if identityish_config_key?(key) do
      redact_identityish_config_value(value)
    else
      PrivacyRedactor.mask_identity(value)
    end
  end

  defp identityish_config_key?(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@identity_key_fragments, &String.contains?(key, &1))
  end

  defp redact_identityish_config_value(value) when is_binary(value) do
    case PrivacyRedactor.mask_cid(value) do
      ^value -> if(String.contains?(value, "•••"), do: value, else: "•••")
      masked -> masked
    end
  end

  defp redact_identityish_config_value(values) when is_list(values),
    do: Enum.map(values, &redact_identityish_config_value/1)

  defp redact_identityish_config_value(%{} = value), do: PrivacyRedactor.mask_identity(value)
  defp redact_identityish_config_value(value), do: value

  defp overlay_for_privacy(overlay, false), do: overlay

  defp overlay_for_privacy(overlay, true) when is_list(overlay) do
    Enum.map(overlay, fn
      %{} = ev -> Map.update(ev, "payload", %{}, &PrivacyRedactor.mask_identity/1)
      ev -> ev
    end)
  end

  defp overlay_for_privacy(overlay, _privacy?), do: overlay

  defp redact_string(value, false), do: value
  defp redact_string(value, true) when is_binary(value), do: PrivacyRedactor.mask_cid(value)
  defp redact_string(value, true), do: value

end
