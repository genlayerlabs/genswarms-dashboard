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
          %{"type" => "metrics", "title" => "Summary", "items" => [...]},
          %{"type" => "table", "title" => "Items", "columns" => [...], "rows" => [...]}
        ]
      }

  The renderer treats every value as display data. Unknown or malformed blocks are
  ignored, and large collections are capped so an extension cannot overwhelm the
  dashboard shell.
  """
  use SubzeroSwarmDashboardWeb, :html

  @id_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/
  @max_pages 12
  @max_sections 12
  @max_metric_items 8
  @max_columns 12
  @max_rows 100

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

  def page(assigns) do
    assigns =
      assigns
      |> assign(:sections, sections(assigns.page))
      |> assign(:dom_id, "extension-page-" <> assigns.page["id"])

    ~H"""
    <div id={@dom_id} class="space-y-5 max-w-6xl">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <h1 class="text-2xl">{@page["label"]}</h1>
        <span :if={@page["meta"]} class="text-xs opacity-50 font-mono">{@page["meta"]}</span>
      </div>

      <%= if @sections == [] do %>
        <.empty_state msg="No extension data yet." />
      <% else %>
        <.section :for={section <- @sections} section={section} />
      <% end %>
    </div>
    """
  end

  attr :section, :map, required: true

  defp section(%{section: %{"type" => "metrics"} = section} = assigns) do
    assigns =
      assigns
      |> assign(:title, section["title"] || "Metrics")
      |> assign(:meta, display(section["meta"]))
      |> assign(:items, metric_items(section["items"]))

    ~H"""
    <.panel title={@title}>
      <:meta :if={@meta}>{@meta}</:meta>
      <div :if={@items != []} class="grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-3">
        <.metric
          :for={item <- @items}
          label={item["label"]}
          value={display(item["value"])}
          sub={display(item["sub"])}
          tone={tone(item["tone"])}
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
      |> assign(:rows, rows(section["rows"]))

    ~H"""
    <.panel title={@title} body_class="px-4 py-2">
      <:meta :if={@meta}>{@meta}</:meta>
      <div :if={@columns != [] and @rows != []} class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th
                :for={col <- @columns}
                class={col_align(col)}
              >
                {col["label"]}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
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
      "tone" => item["tone"]
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

  defp num(n) when is_number(n) do
    n |> trunc() |> Integer.to_string() |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp float(n) when is_float(n) do
    if n == trunc(n) do
      num(n)
    else
      :erlang.float_to_binary(n, [:compact, decimals: 6])
    end
  end
end
