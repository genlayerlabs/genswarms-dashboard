defmodule SubzeroSwarmDashboardWeb.ExtensionPageLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboardWeb.ExtensionPages

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, page_id: id, page_title: "Extension")}
  end

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true

    assigns =
      assign(assigns,
        layout_snapshot: layout_snapshot(assigns[:snapshot], privacy?),
        page: page_for_privacy(ExtensionPages.find(assigns.snapshot, assigns.page_id), privacy?)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={"extension:" <> @page_id}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <%= if @page do %>
        <ExtensionPages.page page={@page} />
      <% else %>
        <div class="max-w-3xl">
          <.empty_state
            msg="Extension unavailable."
            hint="This page appears when the connected swarm publishes it in dashboard_pages."
          />
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp page_for_privacy(page, false), do: page
  defp page_for_privacy(nil, _privacy?), do: nil

  defp page_for_privacy(page, true) do
    page
    |> PrivacyRedactor.mask_identity()
    |> mask_extension_payload()
  end

  defp mask_extension_payload(%{} = map) do
    Map.new(map, fn {key, value} -> {key, mask_extension_value(key, value)} end)
  end

  defp mask_extension_payload(values) when is_list(values),
    do: Enum.map(values, &mask_extension_payload/1)

  defp mask_extension_payload(value), do: value

  defp mask_extension_value(key, value) when is_binary(value) do
    if structural_key?(key) do
      PrivacyRedactor.mask_cid(value)
    else
      PrivacyRedactor.mask_text(value)
    end
  end

  defp mask_extension_value(_key, value), do: mask_extension_payload(value)

  defp structural_key?(key) when key in ["id", "icon", "type", "title", "key", "align", "tone"],
    do: true

  defp structural_key?(_key), do: false

  defp layout_snapshot(snapshot, false), do: snapshot
  defp layout_snapshot(snapshot, true), do: PrivacyRedactor.mask_identity(snapshot)
end
