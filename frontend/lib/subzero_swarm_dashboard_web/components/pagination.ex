defmodule SubzeroSwarmDashboardWeb.Pagination do
  use SubzeroSwarmDashboardWeb, :html

  def page(value) when is_integer(value) and value > 0, do: value

  def page(value) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  def page(_), do: 1

  def slice(rows, requested_page, size \\ 50) do
    total = length(rows)
    page_count = max(div(total + size - 1, size), 1)
    page = min(page(requested_page), page_count)
    offset = (page - 1) * size

    {Enum.slice(rows, offset, size),
     %{
       total: total,
       page: page,
       page_count: page_count,
       first: if(total == 0, do: 0, else: offset + 1),
       last: min(offset + size, total)
     }}
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :pagination, :map, required: true
  attr :sec, :any, default: nil

  def pager(assigns) do
    assigns = assign(assigns, :form, to_form(%{"page" => assigns.pagination.page}))

    ~H"""
    <nav id={@id} aria-label="Pagination" class="flex flex-wrap items-center gap-2 py-3 text-xs">
      <span class="font-mono tnum mr-auto">
        {@pagination.first}–{@pagination.last} of {@pagination.total}
      </span>
      <button
        :for={
          {suffix, label, target, disabled} <- [
            {"first", "First", 1, @pagination.page == 1},
            {"previous", "Previous", @pagination.page - 1, @pagination.page == 1},
            {"next", "Next", @pagination.page + 1, @pagination.page == @pagination.page_count},
            {"last", "Last", @pagination.page_count, @pagination.page == @pagination.page_count}
          ]
        }
        id={"#{@id}-#{suffix}"}
        type="button"
        class="btn btn-ghost btn-xs"
        disabled={disabled}
        phx-click={@event}
        phx-value-page={target}
        phx-value-sec={@sec}
      >
        {label}
      </button>
      <.form for={@form} id={"#{@id}-jump"} phx-submit={@event} class="flex items-center gap-2">
        <input :if={@sec != nil} type="hidden" name="sec" value={@sec} />
        <label for={"#{@id}-number"}>Page</label>
        <.input
          field={@form[:page]}
          id={"#{@id}-number"}
          type="number"
          min="1"
          max={@pagination.page_count}
          class="input input-bordered input-xs w-20"
        />
        <span>of {@pagination.page_count}</span>
        <button type="submit" class="btn btn-ghost btn-xs">Go</button>
      </.form>
    </nav>
    """
  end
end
