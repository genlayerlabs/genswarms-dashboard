defmodule SubzeroSwarmDashboardWeb.ExtensionPages do
  @moduledoc """
  Declarative dashboard pages supplied by the host snapshot.

  Hosts can publish `extensions["dashboard_pages"]` without adding host-specific
  LiveView code:

      %{
        "id" => "custom-report",
        "label" => "Custom report",
        "icon" => "hero-puzzle-piece",
        "sections" => [
          %{"type" => "metrics", "title" => "Summary", "columns" => 2, "items" => [...]},
          %{"type" => "table", "title" => "Items", "columns" => [...], "rows" => [...]}
        ]
      }

  Metrics may request 2 or 4 responsive columns. Metric items may provide `title`
  for exact hover detail and `wrap_sub: true` for explanatory notes. The renderer
  treats every value as display data. Unknown or malformed blocks are ignored, and
  large collections are capped so an extension cannot overwhelm the dashboard shell.
  """
  use SubzeroSwarmDashboardWeb, :html

  @id_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/
  @max_pages 12
  @max_sections 12
  @max_metric_items 8
  @max_columns 12
  @max_rows 100
  @max_tabs 6

  def pages(snapshot) do
    snapshot
    |> get_in(["extensions", "dashboard_pages"])
    |> normalize_pages()
  end

  def find(snapshot, id) when is_binary(id) do
    Enum.find(pages(snapshot), &(&1["id"] == id))
  end

  def find(_snapshot, _id), do: nil

  def active_key(%{"id" => id}), do: "extension:" <> id
  def active_key(_), do: nil

  attr :page, :map, required: true
  attr :sort, :map, default: %{}
  attr :tab, :map, default: %{}
  attr :row_targets, :map, default: %{}

  def page(assigns) do
    sections = assigns.page |> sections() |> Enum.with_index()

    # A page with exactly ONE tabs section gets that selector hoisted into the
    # page header — same top-right placement as the Usage range control. Pages
    # with several tabs sections keep each control inline next to its section.
    hoisted =
      case Enum.filter(sections, fn {sec, _} -> sec["type"] == "tabs" end) do
        [{sec, idx}] -> {idx, normalize_tabs(sec["tabs"])}
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:sections, sections)
      |> assign(:hoisted, hoisted)
      |> assign(:dom_id, "extension-page-" <> assigns.page["id"])

    ~H"""
    <div id={@dom_id} class="space-y-5 max-w-6xl">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <h1 class="text-2xl">{@page["label"]}</h1>
        <div class="flex items-center gap-4">
          <span :if={@page["meta"]} class="text-xs opacity-50 font-mono">{@page["meta"]}</span>
          <.tab_control
            :if={@hoisted}
            idx={elem(@hoisted, 0)}
            tabs={elem(@hoisted, 1)}
            active={tab_active(@tab, elem(@hoisted, 0), elem(@hoisted, 1))}
            class="ext-page-selector"
          />
        </div>
      </div>

      <%= if @sections == [] do %>
        <.empty_state msg="No extension data yet." />
      <% else %>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-5">
          <div
            :for={{section, idx} <- @sections}
            class={span_class(section)}
          >
            <.section
              section={section}
              idx={idx}
              sort={Map.get(@sort, idx)}
              sort_map={@sort}
              tab={@tab}
              hoisted_idx={@hoisted && elem(@hoisted, 0)}
              row_targets={@row_targets}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :idx, :any, default: 0
  attr :sort, :any, default: nil
  attr :sort_map, :map, default: %{}
  attr :tab, :map, default: %{}
  attr :hoisted_idx, :any, default: nil
  attr :row_targets, :map, default: %{}

  defp section(%{section: %{"type" => "metrics"} = section} = assigns) do
    assigns =
      assigns
      |> assign(:title, section["title"] || "Metrics")
      |> assign(:meta, display(section["meta"]))
      |> assign(:items, metric_items(section["items"]))
      |> assign(:grid_class, metric_grid_class(section))

    ~H"""
    <.panel title={@title}>
      <:meta :if={@meta}>{@meta}</:meta>
      <div :if={@items != []} class={["grid gap-x-4 gap-y-3", @grid_class]}>
        <.metric
          :for={item <- @items}
          label={item["label"]}
          value={display(item["value"])}
          sub={display(item["sub"])}
          tone={tone(item["tone"])}
          title={display(item["title"])}
          wrap_sub={item["wrap_sub"]}
        />
      </div>
      <div :if={@items == []} class="text-sm opacity-50 py-1">No data.</div>
    </.panel>
    """
  end

  defp section(%{section: %{"type" => "table"} = section} = assigns) do
    assigns =
      assigns
      |> assign(:title, section["title"] || "Table")
      |> assign(:meta, display(section["meta"]))
      |> assign(:columns, columns(section["columns"]))
      |> assign(
        :rows,
        section["rows"] |> rows() |> Enum.with_index() |> sort_rows(assigns[:sort])
      )

    ~H"""
    <.panel title={@title} body_class="px-4 py-2">
      <:meta :if={@meta}>{@meta}</:meta>
      <div :if={@columns != [] and @rows != []} class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th :for={col <- @columns} class={[col_align(col), "p-0"]}>
                <button
                  type="button"
                  phx-click="ext_sort"
                  phx-value-sec={@idx}
                  phx-value-key={col["key"]}
                  class="w-full px-2 py-1 cursor-pointer hover:opacity-100 opacity-80 font-inherit text-inherit text-left"
                  title="sort"
                >
                  {col["label"]}{sort_marker(@sort, col["key"])}
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{row, ridx} <- @rows}
              class={Map.has_key?(@row_targets, {@idx, ridx}) && "row-press"}
              phx-click={Map.has_key?(@row_targets, {@idx, ridx}) && "inspect"}
              phx-value-session_id={Map.get(@row_targets, {@idx, ridx})}
            >
              <td :for={col <- @columns} class={["max-w-xs", col_align(col)]}>
                <span class={cell_class(col)}>{display(Map.get(row, col["key"]))}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={@columns == [] or @rows == []} class="text-sm opacity-50 py-1">No data.</div>
    </.panel>
    """
  end

  # A segmented control over nested sections: each tab carries ONE inner
  # metrics/table/text section; only the active tab's section is in the DOM.
  # Inner sections get the composite index "<idx>/<tab>" so their sort state
  # and row->inspector targets stay scoped to their own tab.
  defp section(%{section: %{"type" => "tabs"} = section} = assigns) do
    tabs = normalize_tabs(section["tabs"])
    active = tab_active(assigns.tab, assigns.idx, tabs)
    inner_idx = "#{assigns.idx}/#{active}"

    assigns =
      assigns
      |> assign(:title, section["title"])
      |> assign(:meta, display(section["meta"]))
      |> assign(:tabs, tabs)
      |> assign(:active, active)
      |> assign(:inline_control?, assigns.hoisted_idx != assigns.idx)
      |> assign(:inner, tabs != [] && Enum.at(tabs, active)["section"])
      |> assign(:inner_idx, inner_idx)
      |> assign(:inner_sort, Map.get(assigns.sort_map, inner_idx))

    ~H"""
    <div :if={@tabs != []} class="space-y-2">
      <div
        :if={@title || @meta || @inline_control?}
        class="flex items-center justify-between gap-4 flex-wrap"
      >
        <div class="flex items-center gap-3">
          <h2 :if={@title} class="text-sm opacity-60">{@title}</h2>
          <span :if={@meta} class="text-xs opacity-50 font-mono">{@meta}</span>
        </div>
        <.tab_control :if={@inline_control?} idx={@idx} tabs={@tabs} active={@active} class={nil} />
      </div>
      <.section
        :if={@inner}
        section={@inner}
        idx={@inner_idx}
        sort={@inner_sort}
        sort_map={@sort_map}
        tab={@tab}
        row_targets={@row_targets}
      />
    </div>
    """
  end

  defp section(%{section: %{"type" => "text"} = section} = assigns) do
    assigns =
      assigns
      |> assign(:title, section["title"] || "Note")
      |> assign(:body, display(section["body"]))

    ~H"""
    <.panel title={@title}>
      <p class="text-sm opacity-70">{@body}</p>
    </.panel>
    """
  end

  defp section(assigns) do
    ~H"""
    <div class="hidden"></div>
    """
  end

  # ── sortable tables ──────────────────────────────────────────────────────────
  # Rows travel WITH their original index so the row→inspector targets (keyed by
  # source position) survive reordering. Numeric-aware: "$0.50", "1,234", "27%"
  # and raw numbers order numerically; everything else falls back to
  # case-insensitive text (numbers always sort before text).

  defp sort_rows(indexed_rows, nil), do: indexed_rows

  defp sort_rows(indexed_rows, {key, dir}) do
    Enum.sort_by(indexed_rows, fn {row, _idx} -> sort_value(Map.get(row, key)) end, dir)
  end

  defp sort_rows(indexed_rows, _), do: indexed_rows

  @doc false
  def sort_value(v) when is_number(v), do: {0, v * 1.0}

  def sort_value(v) when is_binary(v) do
    cleaned = v |> String.replace(["$", ",", "%"], "") |> String.trim()

    case Float.parse(cleaned) do
      {num, ""} -> {0, num}
      _ -> {1, String.downcase(v)}
    end
  end

  def sort_value(nil), do: {2, ""}
  def sort_value(v), do: {1, v |> inspect() |> String.downcase()}

  defp sort_marker({key, :asc}, key), do: " ↑"
  defp sort_marker({key, :desc}, key), do: " ↓"
  defp sort_marker(_sort, _key), do: nil

  @doc """
  Split a page into `{page-with-metadata-stripped, row_targets}`.

  Underscore-prefixed row keys are the page grammar's metadata channel — never
  rendered. `"_cid"` marks a row as inspectable: its target is resolved through
  `DashHooks.inspect_value/3` (the raw cid in the clear, an opaque `inspect:N`
  token in privacy mode — an unresolvable cid simply isn't clickable), keyed by
  `{section_index, row_index}` so sorting can't misroute a click.
  """
  def extract_row_targets(nil, _privacy?, _lookup), do: {nil, %{}}

  def extract_row_targets(page, privacy?, lookup) do
    {sections, targets} =
      page
      |> sections()
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {sec, sidx}, acc ->
        case sec do
          %{"type" => "table", "rows" => rows} when is_list(rows) ->
            {rows2, acc2} =
              rows
              |> Enum.with_index()
              |> Enum.map_reduce(acc, fn {row, ridx}, a ->
                a = put_row_target(a, {sidx, ridx}, row, privacy?, lookup)
                {strip_row_meta(row), a}
              end)

            {Map.put(sec, "rows", rows2), acc2}

          %{"type" => "tabs", "tabs" => tabs} when is_list(tabs) ->
            {tabs2, acc2} =
              tabs
              |> Enum.with_index()
              |> Enum.map_reduce(acc, fn {tab, tidx}, a ->
                case tab do
                  %{"section" => %{"type" => "table", "rows" => rows} = inner}
                  when is_list(rows) ->
                    {rows2, a2} =
                      rows
                      |> Enum.with_index()
                      |> Enum.map_reduce(a, fn {row, ridx}, aa ->
                        aa = put_row_target(aa, {"#{sidx}/#{tidx}", ridx}, row, privacy?, lookup)
                        {strip_row_meta(row), aa}
                      end)

                    {Map.put(tab, "section", Map.put(inner, "rows", rows2)), a2}

                  _ ->
                    {tab, a}
                end
              end)

            {Map.put(sec, "tabs", tabs2), acc2}

          _ ->
            {sec, acc}
        end
      end)

    {Map.put(page, "sections", sections), targets}
  end

  defp put_row_target(acc, key, row, privacy?, lookup) when is_map(row) do
    with cid when is_binary(cid) and cid != "" <- Map.get(row, "_cid"),
         target when is_binary(target) <-
           SubzeroSwarmDashboardWeb.DashHooks.inspect_value(lookup, privacy?, cid) do
      Map.put(acc, key, target)
    else
      _ -> acc
    end
  end

  defp put_row_target(acc, _key, _row, _privacy?, _lookup), do: acc

  defp strip_row_meta(row) when is_map(row) do
    row
    |> Enum.reject(fn {k, _v} -> is_binary(k) and String.starts_with?(k, "_") end)
    |> Map.new()
  end

  defp strip_row_meta(row), do: row

  attr :idx, :any, required: true
  attr :tabs, :list, required: true
  attr :active, :integer, required: true
  attr :class, :any, default: nil

  # The one selector control — the Usage page's range-button family.
  defp tab_control(assigns) do
    assigns = assign(assigns, :indexed, Enum.with_index(assigns.tabs))

    ~H"""
    <div class={["join", @class]}>
      <button
        :for={{tab, i} <- @indexed}
        type="button"
        phx-click="ext_tab"
        phx-value-sec={@idx}
        phx-value-tab={i}
        class={["btn btn-xs join-item", (i == @active && "btn-primary") || "btn-ghost"]}
      >
        {display(tab["label"])}
      </button>
    </div>
    """
  end

  defp tab_active(tab_state, idx, tabs) do
    case Map.get(tab_state, idx, 0) do
      n when is_integer(n) and n >= 0 and n < length(tabs) -> n
      _ -> 0
    end
  end

  defp normalize_pages(pages) when is_list(pages) do
    pages
    |> Stream.map(&normalize_page/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.take(@max_pages)
  end

  defp normalize_pages(_), do: []
  # Contract versioning (schema 1): a page declaring a NEWER schema than this
  # renderer speaks is skipped — forward compatibility by omission, never by
  # guessing. Absent schema ⇒ 1.
  @schema 1
  defp normalize_page(%{"schema" => s}) when is_integer(s) and s > @schema, do: nil

  defp normalize_page(%{"id" => id, "label" => label} = page)
       when is_binary(id) and is_binary(label) do
    if Regex.match?(@id_re, id) do
      %{
        "id" => id,
        "label" => String.slice(label, 0, 40),
        "icon" => normalize_icon(page["icon"]),
        "meta" => display(page["meta"]),
        "sections" => sections(page)
      }
    end
  end

  defp normalize_page(_), do: nil

  defp normalize_icon(icon) when is_binary(icon) do
    if String.starts_with?(icon, "hero-"), do: icon, else: "hero-puzzle-piece"
  end

  defp normalize_icon(_), do: "hero-puzzle-piece"

  defp sections(%{"sections" => sections}) when is_list(sections),
    do: sections |> Stream.filter(&is_map/1) |> Enum.take(@max_sections)

  defp sections(_), do: []

  defp normalize_tabs(tabs) when is_list(tabs) do
    tabs
    |> Stream.filter(&(is_map(&1) and is_map(&1["section"])))
    |> Enum.take(@max_tabs)
  end

  defp normalize_tabs(_), do: []

  # Sections default to the full page width; "span" => "half" opts a section
  # into one column of the two-column grid (summary blocks side by side).
  defp span_class(%{"span" => "half"}), do: "ext-span-half lg:col-span-1"
  defp span_class(_), do: "ext-span-full lg:col-span-2"

  # Financial reconciliations need more horizontal room than terse telemetry.
  # Producers can opt into a stable two-column layout or a comfortable four-column
  # layout that stays 2x2 through laptop widths and expands only at xl.
  defp metric_grid_class(%{"columns" => 2}),
    do: "ext-metrics-cols-2 grid-cols-1 sm:grid-cols-2"

  defp metric_grid_class(%{"columns" => 4}),
    do: "ext-metrics-cols-4 grid-cols-2 xl:grid-cols-4"

  defp metric_grid_class(_),
    do: "ext-metrics-cols-auto grid-cols-2 md:grid-cols-4"

  defp metric_items(items) when is_list(items) do
    items
    |> Stream.filter(&is_map/1)
    |> Stream.filter(&(is_binary(&1["label"]) and Map.has_key?(&1, "value")))
    |> Stream.map(&normalize_metric_item/1)
    |> Enum.take(@max_metric_items)
  end

  defp metric_items(_), do: []

  defp normalize_metric_item(item) do
    %{
      "label" => display_label(item["label"]),
      "value" => item["value"],
      "sub" => item["sub"],
      "tone" => item["tone"],
      "title" => item["title"],
      "wrap_sub" => item["wrap_sub"] == true
    }
  end

  defp columns(cols) when is_list(cols) do
    cols
    |> Stream.filter(&is_map/1)
    |> Stream.filter(&(is_binary(&1["key"]) and is_binary(&1["label"])))
    |> Stream.map(&normalize_column/1)
    |> Enum.take(@max_columns)
  end

  defp columns(_), do: []

  defp normalize_column(col) do
    %{
      "key" => String.slice(col["key"], 0, 64),
      "label" => display_label(col["label"]),
      "align" => col["align"],
      "mono" => col["mono"]
    }
  end

  defp rows(rows) when is_list(rows), do: rows |> Stream.filter(&is_map/1) |> Enum.take(@max_rows)
  defp rows(_), do: []

  defp display(nil), do: nil
  defp display(value) when is_binary(value), do: String.slice(value, 0, 240)
  defp display(value) when is_integer(value), do: num(value)
  defp display(value) when is_float(value), do: float(value)
  defp display(value) when is_boolean(value), do: to_string(value)
  defp display(_), do: "—"

  defp display_label(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp display_label(_), do: ""

  defp tone(tone) when tone in ["warn", "error", "primary"], do: tone
  defp tone(_), do: nil

  defp col_align(%{"align" => "right"}), do: "text-right"
  defp col_align(_), do: nil

  defp cell_class(%{"mono" => true}), do: "font-mono text-xs break-all"
  defp cell_class(%{"align" => "right"}), do: "tnum"
  defp cell_class(_), do: "break-words"

  defp float(n) when is_float(n) do
    if n == trunc(n) do
      num(n)
    else
      :erlang.float_to_binary(n, [:compact, decimals: 6])
    end
  end
end
