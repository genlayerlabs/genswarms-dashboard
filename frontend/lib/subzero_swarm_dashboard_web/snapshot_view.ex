defmodule SubzeroSwarmDashboardWeb.SnapshotView do
  @moduledoc "Projects the shared source snapshot before copying rows into a viewer process."
  alias SubzeroSwarmDashboardWeb.{ExtensionPages, ReplyHealth, SessionsLive, LogsLive, EventsLive}

  # Only these extension blocks are consumed by built-in pages. Host-specific
  # data is rendered through dashboard_pages, selected and paged below.
  @extensions ~w(dashboard_pages consumers replies audience metrics_today usage_tiles inbox_queue)
  @chrome ~w(id label icon group)

  def project(nil, _assigns), do: nil

  def project(snapshot, assigns) do
    sessions = snapshot["sessions"] || []
    extensions = Map.take(snapshot["extensions"] || %{}, @extensions)

    pages =
      Enum.map(ExtensionPages.pages(snapshot), fn page ->
        if page["id"] == assigns[:page_id],
          do: ExtensionPages.project_page(page, assigns),
          else: Map.take(page, @chrome)
      end)

    selected_ids =
      [
        assigns[:session_id],
        assigns[:selected],
        assigns[:cid],
        get_in(assigns, [:inspect, "session_id"])
      ]
      |> Enum.concat(cids(assigns[:story]))
      |> Enum.concat(cids(pages))
      |> Enum.concat(cids(snapshot["nodes"]))
      |> MapSet.new()

    context =
      Enum.filter(sessions, fn row ->
        MapSet.member?(selected_ids, row["session_id"]) or
          (is_binary(row["agent"]) and row["agent"] != "") or row["state"] == "active"
      end)

    paged =
      cond do
        assigns[:dashboard_view] == SessionsLive ->
          SessionsLive.prepare_snapshot(snapshot, assigns)

        assigns[:dashboard_view] in [LogsLive, EventsLive] ->
          matches = SessionsLive.matching_sessions(snapshot, assigns[:session_query] || "")
          shown = Enum.take(matches, 50)

          selected =
            Enum.filter(context, &(&1["session_id"] in [assigns[:selected], assigns[:cid]]))

          rows = Enum.uniq_by(shown ++ selected, & &1["session_id"])

          snapshot
          |> Map.put("sessions", rows)
          |> Map.put("_session_search", %{
            total: length(matches),
            loaded: length(shown),
            limit: 50
          })

        true ->
          Map.put(
            snapshot,
            "sessions",
            Enum.uniq_by(context ++ Enum.take(sessions, 50), & &1["session_id"])
          )
      end

    ids = MapSet.new(context ++ (paged["sessions"] || []), & &1["session_id"])

    extensions =
      extensions
      |> Map.put("dashboard_pages", pages)
      |> project_items("consumers", "session_id", ids)
      |> project_items("replies", "session_id", ids)

    paged
    |> Map.put("extensions", extensions)
    |> Map.put("_context_sessions", context)
    |> Map.put("_sessions_total", length(sessions))
    |> Map.put(
      "_reply_health",
      ReplyHealth.counts(snapshot, assigns[:story], System.os_time(:second))
    )
  end

  def layout(nil), do: nil

  def layout(snapshot) do
    pages =
      Enum.map(get_in(snapshot, ["extensions", "dashboard_pages"]) || [], fn
        page when is_map(page) -> Map.take(page, @chrome)
        _ -> %{}
      end)

    snapshot
    |> Map.take(~w(swarm dashboard_title))
    |> Map.put("extensions", %{"dashboard_pages" => pages})
  end

  defp project_items(extensions, key, id_key, ids) do
    case extensions[key] do
      %{"items" => items} = block when is_list(items) ->
        Map.put(
          extensions,
          key,
          Map.put(block, "items", Enum.filter(items, &MapSet.member?(ids, &1[id_key])))
        )

      _ ->
        extensions
    end
  end

  # Story tails and selected extension tables are already bounded. Include their
  # targets so an idle conversation outside the sessions page can still open.
  defp cids(%_{}), do: []

  defp cids(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when key in [:cid, "cid", "_cid", "session_id"] and is_binary(value) -> [value]
      {_key, value} -> cids(value)
    end)
  end

  defp cids(list) when is_list(list), do: Enum.flat_map(list, &cids/1)
  defp cids(_value), do: []
end
