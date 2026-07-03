defmodule SubzeroSwarmDashboard.RouterUsageCache do
  @moduledoc """
  Last GOOD router-usage payload per range window — stale-while-revalidate for
  the Usage page. Mount/range-switch paints the cached value instantly (instead
  of `:loading` for the duration of an HTTP round-trip, 8s worst case) while the
  fresh fetch runs; the fetch result then replaces it on screen and in here.

  Only `{:ok, _}` results are stored: an `{:unavailable, _}` must render as the
  error it is (the operator needs to see a down router), it just must never
  become the thing we pre-paint next visit.
  """
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Cached last-good result for a range window, or nil (also nil-safe when not running)."
  def get(range) do
    Agent.get(__MODULE__, &Map.get(&1, range))
  catch
    :exit, _ -> nil
  end

  @doc "Store a fetch result; only successes are kept."
  def put(range, {:ok, _} = result) do
    Agent.update(__MODULE__, &Map.put(&1, range, result))
  catch
    :exit, _ -> :ok
  end

  def put(_range, _result), do: :ok
end
