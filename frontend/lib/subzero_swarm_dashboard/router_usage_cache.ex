defmodule SubzeroSwarmDashboard.RouterUsageCache do
  @moduledoc """
  Shared router usage per range. Last-good values seed mounts; fetches share
  a 60-second freshness window (five seconds for failures). Projections run
  inside the cache so viewers receive only totals or the visible table pages.
  """
  use Agent

  alias SubzeroSwarmDashboard.RouterClient
  alias SubzeroSwarmDashboardWeb.Pagination

  @tables ~w(recent route_health by_served_model by_provider by_route by_model_family)
  @fields ~w(totals health_summary consumer_settings key security detail_level schema_version)

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Cached last-good result for a range window, or nil (also nil-safe when not running)."
  def get(range, projection \\ :full) do
    Agent.get(__MODULE__, &project(get_in(&1, [range, :last_good]), projection))
  catch
    :exit, _ -> nil
  end

  @doc "Store a fetch result; only successes are kept."
  def put(range, {:ok, _} = result) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, range, %{last_good: result}, fn entry ->
        Map.put(entry, :last_good, result)
      end)
    )
  catch
    :exit, _ -> :ok
  end

  def put(_range, _result), do: :ok

  @doc "Fetch once per range/freshness window; call from an async task, never a LiveView callback."
  def fetch(range, opts, projection \\ :full) do
    # ponytail: per-range lock is enough for this low-volume, single-node dashboard;
    # use a supervised shared fetch if callers must survive the fetching viewer exiting.
    :global.trans({{__MODULE__, range}, self()}, fn ->
      cached =
        Agent.get(__MODULE__, fn state ->
          case Map.get(state, range) do
            %{result: result, fetched_at: at} ->
              ttl = if match?({:ok, _}, result), do: 60_000, else: 5_000
              if now() - at < ttl, do: {:fresh, project(result, projection)}, else: :stale

            _ ->
              :stale
          end
        end)

      case cached do
        {:fresh, result} ->
          result

        :stale ->
          result = RouterClient.usage(opts)

          Agent.update(__MODULE__, fn state ->
            entry = Map.get(state, range, %{}) |> Map.merge(%{result: result, fetched_at: now()})

            entry =
              if match?({:ok, _}, result), do: Map.put(entry, :last_good, result), else: entry

            Map.put(state, range, entry)
          end)

          project(result, projection)
      end
    end)
  end

  # Invalid upstream fields must not terminate the shared cache process.
  defp project(result, projection) do
    project_result(result, projection)
  rescue
    _ -> {:unavailable, :invalid_response}
  end

  defp project_result({:ok, body}, :totals) do
    {:ok,
     %{"totals" => Map.take(body["totals"] || %{}, ~w(tokens_total total_tokens requests errors))}}
  end

  defp project_result({:ok, body}, {:page, pages}) do
    {tables, pagination} =
      Enum.reduce(@tables, {%{}, %{}}, fn key, {tables, pagination} ->
        data = body[key]

        rows =
          cond do
            is_map(data) ->
              Enum.sort_by(data, fn {name, stats} -> {-(stats["requests"] || 0), name} end)

            is_list(data) ->
              data

            true ->
              []
          end

        {rows, meta} = Pagination.slice(rows, Map.get(pages, key, 1), 25)
        value = if is_map(data), do: Map.new(rows), else: rows
        {Map.put(tables, key, value), Map.put(pagination, key, meta)}
      end)

    {:ok, body |> Map.take(@fields) |> Map.merge(tables) |> Map.put("pagination", pagination)}
  end

  defp project_result(result, _projection), do: result
  defp now, do: System.monotonic_time(:millisecond)
end
