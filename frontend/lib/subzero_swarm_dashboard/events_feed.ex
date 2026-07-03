defmodule SubzeroSwarmDashboard.EventsFeed do
  @moduledoc """
  Polls the swarm display-event feed (`/api/swarms/:s/events/feed`) every
  `events_poll_ms` (default 700) and folds each event through `Story.Reducer`,
  republishing on the app's `Phoenix.PubSub` (topic `"events"`):

    - `{:display_event, ev}` — per event, arrival-ordered (the canvas hook)
    - `{:story, summary}` — the folded story summary on EVERY poll tick,
      including empty and failed ones: LiveViews only re-render on messages,
      so a quiet feed must still tick or in-flight elapsed freezes, stall
      detection never fires, and the header liveness chip lies

  Cursor discipline (spec §5.2): the FIRST successful poll baselines the cursor
  and discards the ring's history (no replay of pre-boot events). Seqs are
  gapless per feed instance, so a gap proves ring pruning → synthetic
  `feed_gap` issue; a returned cursor BELOW ours proves the feed restarted →
  re-baseline + reset since-baseline state + story note. An unavailable source
  or HTTP error degrades `feed_status` and keeps polling.

  The full story ring / per-cid episodes are pulled on demand via `story_ring/0`
  and `episodes/1` — never shipped to every LiveView at 700ms.
  """
  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias SubzeroSwarmDashboard.SwarmClient
  alias SubzeroSwarmDashboard.Story.{Reducer, State}

  @pubsub SubzeroSwarmDashboard.PubSub
  @topic "events"
  # SwarmFeed broadcasts /dashboard snapshots here; we read them only for the
  # cid → @handle map (events themselves carry just the cid).
  @snapshot_topic "feed"
  @limit 500
  # liveness chip turns amber when the last successful poll is older than this
  @stale_after_s 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Topic LiveViews subscribe to."
  def topic, do: @topic
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @doc "Threshold (s) past which the header chip treats the feed as stale."
  def stale_after_s, do: @stale_after_s

  @doc "Full story ring, newest first — pulled on demand by the Events page."
  def story_ring, do: GenServer.call(__MODULE__, :story_ring)

  @doc """
  Current folded story summary — same shape as the `{:story, summary}` broadcast.
  Lets a freshly mounted LiveView render KPIs/canvas immediately instead of
  waiting for the next poll tick. Nil-safe when the feed isn't running.
  """
  def current_story do
    GenServer.call(__MODULE__, :current_story, 1_000)
  catch
    :exit, _ -> nil
  end

  @doc "Episodes for one cid, newest first — the Session detail REQUESTS section."
  def episodes(cid), do: GenServer.call(__MODULE__, {:episodes, cid})

  @impl true
  def init(_opts) do
    interval = Application.get_env(:subzero_swarm_dashboard, :events_poll_ms, 700)
    swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    PubSub.subscribe(@pubsub, @snapshot_topic)
    send(self(), :poll)

    {:ok,
     %{
       interval: interval,
       swarm: swarm,
       cursor: nil,
       story: new_story(),
       feed_status: :unavailable,
       baseline_at: nil,
       # feed-anchored clock: {ts of the newest folded event, monotonic ms at arrival}
       anchor: nil,
       last_ok_mono: nil
     }}
  end

  @impl true
  def handle_call(:story_ring, _from, state), do: {:reply, state.story.story, state}

  def handle_call(:current_story, _from, state), do: {:reply, summary(state), state}

  def handle_call({:episodes, cid}, _from, state),
    do: {:reply, State.episodes(state.story, cid), state}

  @impl true
  def handle_info(:poll, state) do
    state =
      state.swarm
      |> SwarmClient.events_feed(state.cursor || 0, @limit)
      |> handle_poll(state)

    state = tick_and_broadcast(state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  # /dashboard snapshot (from SwarmFeed): refresh the story's cid → @handle map so
  # event rows render the user, not the raw chat id. Snapshots arrive every few
  # seconds; storing the map is cheap and doesn't touch the cursor or the fold.
  def handle_info({:snapshot, snap}, state),
    do: {:noreply, %{state | story: Reducer.put_users(state.story, handles(snap))}}

  # other "feed" traffic (live WS events, disconnects, warnings) isn't ours to fold.
  def handle_info(_other, state), do: {:noreply, state}

  # the route answers but no events_source is wired host-side (old backend)
  defp handle_poll({:ok, %{"source" => "unavailable"}}, state),
    do: %{state | feed_status: :unavailable}

  # first successful poll: baseline — keep the feed's cursor, discard history
  defp handle_poll({:ok, %{"seq" => seq}}, %{cursor: nil} = state) when is_integer(seq) do
    %{
      state
      | cursor: seq,
        feed_status: :ok,
        baseline_at: DateTime.utc_now(),
        last_ok_mono: now_mono()
    }
  end

  defp handle_poll({:ok, %{"events" => events, "seq" => seq}}, state)
       when is_list(events) and is_integer(seq) do
    if seq < state.cursor,
      do: rebaseline(state, seq),
      else: fold_batch(state, events, seq)
  end

  defp handle_poll({:ok, _malformed}, state), do: %{state | feed_status: :unavailable}
  defp handle_poll({:error, _reason}, state), do: %{state | feed_status: :unavailable}

  # the feed's cursor went backwards: wingston restarted — start over from its
  # new cursor and reset since-baseline state (counters would lie across reboots)
  defp rebaseline(state, seq) do
    story = Reducer.apply(new_story(), %{"kind" => "feed_restart", "ts" => feed_now(state)})

    %{
      state
      | cursor: seq,
        story: story,
        feed_status: :ok,
        baseline_at: DateTime.utc_now(),
        anchor: nil,
        last_ok_mono: now_mono()
    }
  end

  defp fold_batch(state, [], seq),
    do: %{state | cursor: seq, feed_status: :ok, last_ok_mono: now_mono()}

  defp fold_batch(state, [first | _] = events, seq) do
    state =
      case first["seq"] do
        # gapless seqs: a gap proves ring pruning while we lagged → note + resync
        n when is_integer(n) and n > state.cursor + 1 ->
          gap = %{"kind" => "feed_gap", "ts" => first["ts"], "lost" => n - state.cursor - 1}
          %{state | story: Reducer.apply(state.story, gap)}

        _ ->
          state
      end

    story =
      Enum.reduce(events, state.story, fn ev, acc ->
        PubSub.broadcast(@pubsub, @topic, {:display_event, ev})
        Reducer.apply(acc, ev)
      end)

    anchor =
      case List.last(events)["ts"] do
        ts when is_number(ts) -> {ts, now_mono()}
        _ -> state.anchor
      end

    %{
      state
      | story: story,
        cursor: seq,
        feed_status: :ok,
        anchor: anchor,
        last_ok_mono: now_mono()
    }
  end

  defp tick_and_broadcast(state) do
    story = Reducer.tick(state.story, feed_now(state))
    state = %{state | story: story}
    PubSub.broadcast(@pubsub, @topic, {:story, summary(state)})
    state
  end

  defp summary(state) do
    state.story
    |> State.summary()
    |> Map.merge(%{
      feed_status: state.feed_status,
      feed_age_s: feed_age(state),
      baseline_at: state.baseline_at
    })
  end

  # feed-anchored clock (spec §5.3): max event ts seen + monotonic delta since
  # it arrived — host↔container clock skew never shows up as wrong ages
  defp feed_now(%{anchor: {ts, mono}}), do: ts + (now_mono() - mono) / 1000
  defp feed_now(_state), do: System.os_time(:millisecond) / 1000

  defp feed_age(%{last_ok_mono: nil}), do: nil
  defp feed_age(%{last_ok_mono: t}), do: div(now_mono() - t, 1000)

  defp new_story do
    State.new(
      stall_after_ms: Application.get_env(:subzero_swarm_dashboard, :stall_after_ms, 180_000),
      story_max: Application.get_env(:subzero_swarm_dashboard, :story_ring_max, 500),
      issues_max: Application.get_env(:subzero_swarm_dashboard, :issues_ring_max, 200)
    )
  end

  defp now_mono, do: System.monotonic_time(:millisecond)

  # Build cid → @handle from a /dashboard snapshot's sessions, keeping only rows
  # that actually carry a handle (a not-yet-rostered live session has user: nil →
  # the reducer falls back to the chat id). Tolerant of a malformed snapshot.
  defp handles(snap) do
    for %{"session_id" => cid, "user" => %{"handle" => h}} <- sessions(snap),
        is_binary(cid) and is_binary(h) and h != "",
        into: %{},
        do: {cid, h}
  end

  defp sessions(%{"sessions" => list}) when is_list(list), do: list
  defp sessions(_), do: []
end
