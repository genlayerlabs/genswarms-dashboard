defmodule GenswarmsDashboard.FixtureEventsSource do
  @moduledoc """
  Fixture EventsSource for library tests. Records the (since, limit) the plug parsed
  under `:stub_last_feed_query` (global Application env — tests touching it must be
  `async: false`, like the genswarms stubs) and honors the PINNED cursor semantics:
  seq is the feed's current cursor, never an echo of since.
  """
  @behaviour GenswarmsDashboard.EventsSource

  # the second event is deliberately an UNKNOWN kind with arbitrary fields — the
  # backend is kind-agnostic and must relay it verbatim (pinned by the golden contract)
  @feed [
    %{seq: 1, ts: 1_718_000_000.0, kind: "request_open", cid: "fix:1"},
    %{seq: 2, ts: 1_718_000_001.5, kind: "totally_unknown", mystery: %{nested: true}, extra: "verbatim"}
  ]

  @impl true
  def events_since(since, limit) do
    Application.put_env(:genswarms_dashboard, :stub_last_feed_query, {since, limit})
    events = @feed |> Enum.filter(&(&1.seq > since)) |> Enum.take(limit)
    %{events: events, seq: 2}
  end
end

defmodule GenswarmsDashboard.UnavailableEventsSource do
  @moduledoc "EventsSource whose feed is down — the contract's :unavailable return."
  @behaviour GenswarmsDashboard.EventsSource

  @impl true
  def events_since(_since, _limit), do: :unavailable
end

defmodule GenswarmsDashboard.RaisingEventsSource do
  @moduledoc "EventsSource that raises — the route must degrade to unavailable, never 500."
  @behaviour GenswarmsDashboard.EventsSource

  @impl true
  def events_since(_since, _limit), do: raise("feed exploded")
end

defmodule GenswarmsDashboard.ExitingEventsSource do
  @moduledoc "EventsSource that exits (e.g. a dead GenServer behind it) — same degradation."
  @behaviour GenswarmsDashboard.EventsSource

  @impl true
  def events_since(_since, _limit), do: exit(:feed_down)
end
