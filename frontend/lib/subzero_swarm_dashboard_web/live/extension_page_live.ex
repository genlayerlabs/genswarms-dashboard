defmodule SubzeroSwarmDashboardWeb.ExtensionPageLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboardWeb.DashHooks
  alias SubzeroSwarmDashboardWeb.ExtensionPages

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, page_id: id, page_title: "Extension", ext_sort: %{}, ext_tab: %{})}
  end

  @impl true
  def handle_event("ext_sort", %{"sec" => sec, "key" => key}, socket) do
    # Top-level sections key by integer position; tab-nested sections use the
    # composite "<idx>/<tab>" string. Both are opaque map keys past this point.
    idx = section_key(sec)

    next =
      case Map.get(socket.assigns.ext_sort, idx) do
        {^key, :asc} -> {key, :desc}
        {^key, :desc} -> nil
        _ -> {key, :asc}
      end

    sort =
      if next,
        do: Map.put(socket.assigns.ext_sort, idx, next),
        else: Map.delete(socket.assigns.ext_sort, idx)

    {:noreply, assign(socket, ext_sort: sort)}
  end

  @doc """
  Handles tab selection events for extension page sections.

  Validates that `tab` is a numeric string before converting to integer,
  defaulting to 0 for invalid input to prevent ArgumentError crashes.
  """
  @impl true
  def handle_event("ext_tab", %{"sec" => sec, "tab" => tab}, socket) do
    tab_index = if Regex.match?(~r/^\d+$/, tab), do: String.to_integer(tab), else: 0

    {:noreply,
     assign(socket,
       ext_tab: Map.put(socket.assigns.ext_tab, section_key(sec), tab_index)
     )}
  end

  defp section_key(sec) do
    if Regex.match?(~r/^\d+$/, sec), do: String.to_integer(sec), else: sec
  end

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])

    # Row targets resolve BEFORE the privacy mask (mask_cid would destroy the
    # "_cid" metadata); the metadata keys are stripped in the same pass, so no
    # raw cid ever reaches the rendered page in either mode.
    {page, row_targets} =
      ExtensionPages.extract_row_targets(
        ExtensionPages.find(assigns.snapshot, assigns.page_id),
        privacy?,
        inspect_lookup
      )

    assigns =
      assign(assigns,
        layout_snapshot: DashHooks.layout_snapshot(assigns[:snapshot], privacy?),
        row_targets: row_targets,
        page: page_for_privacy(page, privacy?)
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
        <ExtensionPages.page page={@page} sort={@ext_sort} tab={@ext_tab} row_targets={@row_targets} />
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
    |> restore_page_title(page)
  end

  # The page's own h1 is the same operator chrome as its sidebar nav entry —
  # readable (cid-swept), matching DashHooks.layout_snapshot's label restore.
  # Deeper "label" keys (table columns, row cells) stay masked: a row column
  # may legitimately be keyed "label" and carry user data.
  defp restore_page_title(%{} = masked, %{"label" => label}) when is_binary(label),
    do: Map.put(masked, "label", PrivacyRedactor.mask_cid(label))

  defp restore_page_title(masked, _original), do: masked

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
end
