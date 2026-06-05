defmodule SubzeroSwarmDashboardWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label="close">
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">Actions</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(SubzeroSwarmDashboardWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(SubzeroSwarmDashboardWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # ── Telemetry-console components ────────────────────────────────────────────

  @doc """
  A user identity chip: a per-user color monogram + the handle/name, with a
  graceful fallback to the raw conversation id when we don't know the user yet.

  `user` is the dashboard's `session["user"]` map (`%{"handle", "name"}`) or nil.
  """
  attr :user, :any, default: nil
  attr :session_id, :string, default: nil
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :class, :any, default: nil

  def identity(assigns) do
    lines = identity_lines(assigns.user, assigns.session_id)

    size_class =
      case {assigns.size, lines.primary_mono} do
        {:lg, _} -> "text-base"
        {_, true} -> "text-sm"
        _ -> nil
      end

    assigns = assign(assigns, lines: lines, size_class: size_class)

    ~H"""
    <div class={["flex items-center gap-2.5 min-w-0", @class]}>
      <span
        class={["monogram shrink-0", @size == :sm && "!w-7 !h-7 !text-xs", @size == :lg && "!w-10 !h-10 !text-base"]}
        style={monogram_style(@user, @session_id)}
      >
        {@lines.monogram}
      </span>
      <div class="min-w-0 leading-tight">
        <div class={["truncate", @size_class, @lines.primary_mono && "font-mono", !@lines.primary_mono && "font-medium"]}>
          {@lines.primary}
        </div>
        <div :if={@lines.secondary} class="text-xs opacity-55 font-mono truncate">{@lines.secondary}</div>
      </div>
    </div>
    """
  end

  @doc "A pulsing signal dot for `active`, a quiet hollow dot otherwise."
  attr :state, :any, required: true
  attr :label, :boolean, default: false
  attr :class, :any, default: nil

  def live_dot(assigns) do
    active = to_string(assigns.state) == "active"
    assigns = assign(assigns, active: active)

    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]}>
      <span class={["signal-dot", !@active && "signal-dot--idle"]}></span>
      <span :if={@label} class={["text-xs", @active && "text-[var(--signal)] font-medium", !@active && "opacity-55"]}>
        {if @active, do: "live", else: "idle"}
      </span>
    </span>
    """
  end

  @doc """
  The shared slide-over inspector. Driven by the global `@inspect` assign (a
  session map) wired in `DashHooks`; renders nothing when nil. `transcript` carries
  the lazily-loaded durable conversation and `activity` the raw slot output — the
  inspector shows the full detail, so there is no separate "open full session" step.
  """
  attr :inspect, :any, default: nil
  attr :transcript, :any, default: nil
  attr :activity, :any, default: nil

  def inspector(assigns) do
    ~H"""
    <div :if={@inspect}>
      <div class="inspector-backdrop" phx-click="inspect_close" phx-window-keydown="inspect_close" phx-key="Escape">
      </div>
      <aside class="inspector-panel scroll-thin">
        <div class="p-5 space-y-5">
          <div class="flex items-start justify-between gap-3">
            <.identity user={@inspect["user"]} session_id={@inspect["session_id"]} size={:lg} />
            <button class="btn btn-ghost btn-sm btn-circle -mr-1" phx-click="inspect_close" aria-label="Close">
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.live_dot state={@inspect["state"]} label />
            <span class="badge badge-ghost badge-sm">{@inspect["transport"]}</span>
            <span :if={chat_type(@inspect)} class="badge badge-outline badge-sm">{chat_type(@inspect)}</span>
          </div>

          <dl class="grid grid-cols-3 gap-x-3 gap-y-2.5 text-sm">
            <dt class="opacity-50">session</dt>
            <dd class="col-span-2 font-mono text-xs break-all">{@inspect["session_id"]}</dd>
            <dt class="opacity-50">agent slot</dt>
            <dd class="col-span-2 font-mono text-xs">{@inspect["agent"] || "—"}</dd>
            <dt class="opacity-50">last seen</dt>
            <dd class="col-span-2 tnum">{relative_time(@inspect["last_activity"])}</dd>
            <%= for {k, v} <- transport_ref(@inspect) do %>
              <dt class="opacity-50 font-mono text-xs">{k}</dt>
              <dd class="col-span-2 font-mono text-xs break-all">{v}</dd>
            <% end %>
          </dl>

          <div class="border-t border-base-300 pt-4">
            <div class="text-xs uppercase tracking-wide opacity-50 mb-1">Conversation</div>
            <p class="text-xs opacity-50 mb-2">Clean user ↔ bot history, saved to the DB — survives restarts.</p>
            <.inspector_transcript transcript={@transcript} />
          </div>

          <div class="border-t border-base-300 pt-4">
            <div class="text-xs uppercase tracking-wide opacity-50 mb-1">Agent activity · live</div>
            <p class="text-xs opacity-50 mb-2">The agent's raw working log for this slot — tool calls, results, sends. Ephemeral.</p>
            <.activity_timeline activity={@activity} />
          </div>
        </div>
      </aside>
    </div>
    """
  end

  attr :transcript, :any, default: nil

  # Full durable transcript — every turn, untruncated, as chat bubbles (mirrors the
  # dedicated session page so the inspector is a complete view, not a peek).
  defp inspector_transcript(%{transcript: {:ok, %{"turns" => [_ | _] = turns} = body}} = assigns) do
    assigns = assign(assigns, turns: turns, source: body["source"])

    ~H"""
    <div :if={@source} class="text-xs opacity-50 mb-2">source: {@source}</div>
    <div class="space-y-2">
      <div :for={t <- @turns} class={["chat", (t["role"] == "user" && "chat-start") || "chat-end"]}>
        <div class="chat-header text-xs opacity-60">{t["role"]}</div>
        <div class="chat-bubble whitespace-pre-wrap break-words">{t["content"]}</div>
      </div>
    </div>
    """
  end

  defp inspector_transcript(%{transcript: {:ok, %{"source" => source}}} = assigns) do
    assigns = assign(assigns, :source, source)

    ~H"""
    <div class="text-sm opacity-50">No transcript ({@source}).</div>
    """
  end

  defp inspector_transcript(%{transcript: :loading} = assigns),
    do: ~H"""
    <div class="text-sm opacity-50">loading…</div>
    """

  defp inspector_transcript(assigns),
    do: ~H"""
    <div class="text-sm opacity-50">No transcript yet.</div>
    """

  @doc """
  Shared raw-slot **activity timeline**. Renders the per-agent slot output on a
  vertical timeline, but classifies each entry so the *conversation* reads cleanly
  while the *machinery* stays out of the way:

    - real user / assistant turns → colored chat lines (the orchestrator relay
      prefix is stripped; an outgoing `reply` payload shows its `text`, not the
      `swarm-msg` plumbing);
    - everything else (tool shell calls, exit results, inter-object `[From …]`
      messages, raw JSON) → a small `<details>` badge that expands to the raw text.

  Accepts the same `{:ok, %{"logs" => […]}}` / `:loading` / other shapes the swarm
  read API returns, so the session page, the inspector, and the Logs page all share it.
  """
  attr :activity, :any, required: true

  def activity_timeline(%{activity: {:ok, %{"logs" => [_ | _] = entries} = body}} = assigns) do
    assigns = assign(assigns, rows: Enum.map(entries, &classify_activity/1), source: body["source"])

    ~H"""
    <div :if={@source} class="text-xs opacity-50 mb-2">source: {@source}</div>
    <ol class="relative border-l border-base-300 ml-2 space-y-3">
      <li :for={r <- @rows} class="ml-4">
        <span class={["absolute -left-1.5 top-1 w-3 h-3 rounded-full", activity_dot(r.kind)]}></span>
        <.activity_row row={r} />
      </li>
    </ol>
    """
  end

  def activity_timeline(%{activity: {:ok, _}} = assigns),
    do: ~H"""
    <div class="text-sm opacity-50">No raw output (slot recycled or never ran).</div>
    """

  def activity_timeline(%{activity: :loading} = assigns),
    do: ~H"""
    <div class="text-sm opacity-50">loading…</div>
    """

  def activity_timeline(assigns),
    do: ~H"""
    <div class="text-sm opacity-50">Activity unavailable.</div>
    """

  # A real conversation turn — colored chat line on the timeline.
  defp activity_row(%{row: %{kind: kind}} = assigns) when kind in [:user, :assistant] do
    ~H"""
    <div class="flex items-baseline gap-2 text-xs opacity-60">
      <time class="font-mono">{@row.ts}</time>
      <span class={["badge badge-xs", (@row.kind == :user && "badge-primary") || "badge-secondary"]}>
        {@row.kind}
      </span>
    </div>
    <div class="text-sm whitespace-pre-wrap break-words mt-0.5">{@row.text}</div>
    """
  end

  # An outbound reply that was actually executed (swarm-msg send ran) → delivered.
  defp activity_row(%{row: %{kind: :sent}} = assigns) do
    ~H"""
    <div class="flex items-baseline gap-2 text-xs opacity-60">
      <time class="font-mono">{@row.ts}</time>
      <span class="badge badge-success badge-xs">sent →</span>
    </div>
    <div class="text-sm whitespace-pre-wrap break-words mt-0.5">{@row.text}</div>
    """
  end

  # An assistant turn that is a tool-call emitted AS TEXT — never executed, so the
  # reply was never sent. This is the signal that was previously masked.
  defp activity_row(%{row: %{kind: :tool_intent}} = assigns) do
    ~H"""
    <details class="group">
      <summary class="flex items-baseline gap-2 cursor-pointer list-none text-xs">
        <time class="font-mono opacity-60">{@row.ts}</time>
        <span class="badge badge-warning badge-xs">⚠ not delivered</span>
        <span class="opacity-70 truncate max-w-[18rem]">{@row.text}</span>
        <span class="opacity-40 group-open:rotate-90 transition-transform">›</span>
      </summary>
      <div class="mt-1 text-xs text-warning">
        Model emitted a tool call as text — it was NOT executed, so this reply never sent
        (native tool-calling not returned by the router/model).
      </div>
      <pre class="mt-1 text-xs whitespace-pre-wrap break-words bg-base-300/40 rounded p-2 overflow-x-auto">{@row.content}</pre>
    </details>
    """
  end

  # System noise — a small badge that expands to the raw text.
  defp activity_row(assigns) do
    ~H"""
    <details class="group">
      <summary class="flex items-baseline gap-2 cursor-pointer list-none text-xs opacity-50 hover:opacity-90">
        <time class="font-mono">{@row.ts}</time>
        <span class="badge badge-ghost badge-xs">{@row.label}</span>
        <span class="truncate max-w-[18rem] opacity-70">{@row.preview}</span>
        <span class="opacity-40 group-open:rotate-90 transition-transform">›</span>
      </summary>
      <pre class="mt-1 text-xs whitespace-pre-wrap break-words bg-base-300/40 rounded p-2 overflow-x-auto">{@row.content}</pre>
    </details>
    """
  end

  # ── activity classification (pure) ──────────────────────────────────────────

  @doc """
  Classify one raw activity entry into a timeline row. Pure; public for tests.
  Returns a map with `:kind`:
    - `:user` / `:assistant` — a real conversation turn (colored chat);
    - `:sent` — an outbound reply that was actually executed (delivered);
    - `:tool_intent` — an assistant turn that is a tool call emitted AS TEXT and
      therefore NEVER executed/delivered (the previously-masked failure signal);
    - `:noise` — tool plumbing, results, inter-object hops.
  plus the fields the row renderer needs.
  """
  def classify_activity(e) do
    role = to_string(e["role"] || "")
    content = to_string(e["content"] || "")
    ts = e["timestamp"]
    trimmed = String.trim_leading(content)

    cond do
      # The orchestrator relays the human's Telegram messages — that IS the user.
      role == "user" and String.starts_with?(trimmed, "[From orchestrator]") ->
        %{kind: :user, ts: ts, text: clean_chat(content)}

      # Any other inter-object hop ([From policy], [From sender], …) is plumbing.
      Regex.match?(~r/^\[From \w+\]/, trimmed) ->
        noise_row(role, content, ts)

      role == "user" ->
        %{kind: :user, ts: ts, text: clean_chat(content)}

      # An assistant turn that is a tool-call blob = emitted as TEXT, NOT executed.
      # The reply was never sent — flag it, don't render it as a delivered message.
      role in ["asst", "assistant"] and tool_call_text?(content) ->
        %{kind: :tool_intent, ts: ts, text: reply_text(content) || one_line(content), content: content}

      # Tool plumbing: an executed reply (the shell ran swarm-msg send with a
      # reply payload) shows as delivered; anything else is noise.
      role in ["tool", "result", "res"] ->
        case reply_text(content) do
          nil -> noise_row(role, content, ts)
          txt -> %{kind: :sent, ts: ts, text: txt}
        end

      # A plain natural-language assistant turn.
      role in ["asst", "assistant"] and not machinery?(content) ->
        %{kind: :assistant, ts: ts, text: String.trim(content)}

      true ->
        noise_row(role, content, ts)
    end
  end

  # An assistant message that is really a tool call rendered as text: explicit
  # <tool_call> wrapper, or a bare JSON object carrying cmd/command/action.
  defp tool_call_text?(content) do
    t = String.trim_leading(content)

    String.starts_with?(t, "<tool_call>") or
      (String.starts_with?(t, "{") and
         (String.contains?(t, "\"cmd\"") or String.contains?(t, "\"command\"") or
            String.contains?(t, "\"action\"")))
  end

  defp noise_row(role, content, ts) do
    %{kind: :noise, ts: ts, label: noise_label(role, content), preview: one_line(content), content: content}
  end

  # Strip the orchestrator/relay prefix so the user's words stand alone.
  defp clean_chat(content), do: content |> String.replace(~r/^\s*\[From \w+\]\s*/, "") |> String.trim()

  # Pull the human-facing `text` out of a `{"action":"reply",…,"text":"…"}` payload,
  # tolerating the escaped form inside a `{"cmd":"…"}` / heredoc blob. nil if absent.
  defp reply_text(content) do
    unescaped = content |> String.replace("\\\"", "\"") |> String.replace("\\n", "\n")

    case Regex.run(~r/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/, unescaped) do
      [_, t] -> t |> String.replace("\\n", "\n") |> String.replace("\\t", "\t") |> String.trim()
      _ -> nil
    end
  end

  # Does this assistant content look like tooling rather than a spoken reply?
  defp machinery?(content) do
    t = String.trim_leading(content)
    String.starts_with?(t, "{") or String.starts_with?(t, "shell:") or
      String.starts_with?(t, "cat ") or String.contains?(t, "swarm-msg")
  end

  defp noise_label(role, content) do
    case Regex.run(~r/^\s*\[From (\w+)\]/, content) do
      [_, from] -> "#{from} →"
      _ -> if role == "", do: "log", else: role
    end
  end

  defp one_line(content), do: content |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 90)

  defp activity_dot(:user), do: "bg-primary"
  defp activity_dot(:assistant), do: "bg-secondary"
  defp activity_dot(:sent), do: "bg-success"
  defp activity_dot(:tool_intent), do: "bg-warning"
  defp activity_dot(_), do: "bg-base-content/20"

  # ── identity / formatting helpers ───────────────────────────────────────────

  @doc false
  def identity_lines(user, session_id) do
    handle = present(user && user["handle"])
    name = present(user && user["name"])
    at = handle && "@#{handle}"
    cid = short_cid(session_id)

    cond do
      name && handle -> %{monogram: initial(name), primary: name, secondary: at, primary_mono: false}
      name -> %{monogram: initial(name), primary: name, secondary: cid, primary_mono: false}
      handle -> %{monogram: initial(handle), primary: at, secondary: cid, primary_mono: false}
      # group/topic chat with no known speaker — the negative chat id isn't a person.
      group_cid?(cid) -> %{monogram: "⌗", primary: "Group chat", secondary: cid, primary_mono: false}
      true -> %{monogram: "#", primary: cid || "unknown", secondary: nil, primary_mono: true}
    end
  end

  defp group_cid?("-" <> _), do: true
  defp group_cid?(_), do: false

  @doc false
  def monogram_style(user, session_id) do
    seed = (present(user && user["handle"]) || present(user && user["name"]) || to_string(session_id) || "x")
    hue = :erlang.phash2(seed, 360)

    "background: linear-gradient(145deg, oklch(0.62 0.13 #{hue}), oklch(0.42 0.09 #{hue})); color: white; border-color: oklch(0.7 0.12 #{hue} / 0.5);"
  end

  defp initial(nil), do: "#"
  defp initial(s) do
    s |> String.trim() |> String.first() |> to_string() |> String.upcase()
  end

  # "tg:903489662:0" -> "903489662"
  defp short_cid("tg:" <> rest), do: rest |> String.split(":") |> List.first()
  defp short_cid(cid) when is_binary(cid), do: cid
  defp short_cid(_), do: nil

  defp chat_type(%{"metadata" => %{"chat_type" => t}}) when is_binary(t), do: t
  defp chat_type(_), do: nil

  defp transport_ref(%{"transport_ref" => ref}) when is_map(ref), do: ref
  defp transport_ref(_), do: %{}

  defp present(nil), do: nil
  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil

  @doc "Human relative time from an ISO8601 string (or `—`)."
  def relative_time(nil), do: "—"
  def relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        secs = DateTime.diff(DateTime.utc_now(), dt)
        cond do
          secs < 5 -> "just now"
          secs < 60 -> "#{secs}s ago"
          secs < 3600 -> "#{div(secs, 60)}m ago"
          secs < 86_400 -> "#{div(secs, 3600)}h ago"
          true -> "#{div(secs, 86_400)}d ago"
        end

      _ ->
        iso
    end
  end

  def relative_time(_), do: "—"
end
