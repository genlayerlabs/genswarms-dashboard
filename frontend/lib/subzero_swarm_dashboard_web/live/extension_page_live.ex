defmodule SubzeroSwarmDashboardWeb.ExtensionPageLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboardWeb.ExtensionPages

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, page_id: id, page_title: "Extension")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :page, ExtensionPages.find(assigns.snapshot, assigns.page_id))

    ~H"""
    <Layouts.app
      flash={@flash}
      active={"extension:" <> @page_id}
      swarm={@swarm}
      snapshot={@snapshot}
      story={@story}
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
end
