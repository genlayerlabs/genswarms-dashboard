defmodule SubzeroSwarmDashboardWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SubzeroSwarmDashboardWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the active nav key"
  attr :swarm, :string, default: nil, doc: "the swarm name shown in the sidebar"
  attr :snapshot, :any, default: nil, doc: "the latest dashboard snapshot"
  attr :story, :any, default: nil, doc: "the folded story summary (feeds the liveness chip)"
  attr :inspect, :any, default: nil, doc: "the session currently open in the inspector"
  attr :inspect_transcript, :any, default: nil, doc: "lazily-loaded durable transcript"
  attr :inspect_activity, :any, default: nil, doc: "lazily-loaded raw slot activity"
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign(
        assigns,
        :extension_pages,
        SubzeroSwarmDashboardWeb.ExtensionPages.pages(assigns[:snapshot])
      )

    ~H"""
    <div class="flex min-h-screen">
      <aside class="console-rail w-60 shrink-0 border-r border-base-300 px-3 py-5 flex flex-col">
        <div class="px-2 mb-7 flex items-center gap-2.5">
          <img src={~p"/images/logo.svg"} width="30" class="drop-shadow" />
          <div class="leading-none">
            <div class="font-display font-extrabold text-lg tracking-tight">SWARM</div>
            <div class="text-[0.65rem] uppercase tracking-[0.22em] opacity-50 mt-0.5">console</div>
          </div>
        </div>

        <div class="px-2 mb-5 space-y-2">
          <div class="flex items-center gap-2 rounded-lg bg-base-100/60 border border-base-300 px-2.5 py-1.5">
            <span class="signal-dot"></span>
            <span class="font-mono text-xs truncate">{@swarm || "—"}</span>
          </div>
          <.feed_chip story={@story} />
        </div>

        <ul class="menu w-full gap-0.5 px-0">
          <.nav_item
            active={@active}
            key={:overview}
            href={~p"/"}
            icon="hero-squares-2x2"
            label="Overview"
          />
          <.nav_item
            active={@active}
            key={:topology}
            href={~p"/topology"}
            icon="hero-cpu-chip"
            label="Topology"
          />
          <.nav_item
            active={@active}
            key={:sessions}
            href={~p"/sessions"}
            icon="hero-chat-bubble-left-right"
            label="Sessions"
          />
          <.nav_item
            active={@active}
            key={:events}
            href={~p"/events"}
            icon="hero-bolt"
            label="Events"
          />
          <.nav_item
            active={@active}
            key={:usage}
            href={~p"/usage"}
            icon="hero-chart-bar"
            label="Usage"
          />
          <.nav_item
            :for={page <- @extension_pages}
            active={@active}
            key={SubzeroSwarmDashboardWeb.ExtensionPages.active_key(page)}
            href={"/extensions/#{page["id"]}"}
            icon={page["icon"]}
            label={page["label"]}
          />
          <.nav_item
            active={@active}
            key={:logs}
            href={~p"/logs"}
            icon="hero-document-text"
            label="Logs"
          />
        </ul>
        <div class="mt-auto pt-6 px-2"><.theme_toggle /></div>
      </aside>

      <main class="flex-1 p-6 lg:p-8 overflow-x-auto">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.inspector inspect={@inspect} transcript={@inspect_transcript} activity={@inspect_activity} />
    <.flash_group flash={@flash} />
    """
  end

  attr :story, :any, default: nil

  # The dashboard's dead-man switch (spec §5.4): green while the events feed
  # answers, amber when it's unreachable or the last successful poll went stale.
  # Hidden until the first {:story, ...} broadcast arrives.
  defp feed_chip(assigns) do
    ~H"""
    <div
      :if={@story}
      id="feed-chip"
      title="Time since the display-event feed last answered. Amber means the feed is unreachable or stale — live story panels may lag; snapshot-driven content is unaffected."
      class={[
        "flex items-center gap-2 rounded-lg border px-2.5 py-1.5 font-mono text-xs",
        if(feed_fresh?(@story),
          do: "border-success/30 text-success",
          else: "border-warning/40 text-warning"
        )
      ]}
    >
      <.icon name="hero-signal" class="size-3.5 shrink-0" />
      <span class="truncate">{feed_label(@story)}</span>
    </div>
    """
  end

  defp feed_fresh?(story) do
    story[:feed_status] == :ok and
      (story[:feed_age_s] || 0) <= SubzeroSwarmDashboard.EventsFeed.stale_after_s()
  end

  defp feed_label(%{feed_status: :ok} = story), do: "feed #{story[:feed_age_s] || 0}s ago"
  defp feed_label(_story), do: "feed unavailable"

  attr :active, :any, default: nil
  attr :key, :any, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@href}
        class={[
          "font-medium gap-2.5 rounded-lg",
          @active == @key && "bg-primary/15 text-primary border border-primary/25",
          @active != @key && "border border-transparent opacity-75 hover:opacity-100"
        ]}
      >
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        {@label}
      </.link>
    </li>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
