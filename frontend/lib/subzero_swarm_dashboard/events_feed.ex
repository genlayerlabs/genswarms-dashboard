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
  # ── restart persistence ──────────────────────────────────────────────────────
  # The fold lives in this process's memory; without a snapshot every dashboard
  # deploy wiped issues/KPIs/"observed since". State is saved every
  # @persist_every_ms (and on terminate) and restored at init — cursor included,
  # so the next poll CONTINUES (catching up ≤ ring size) instead of
  # re-baselining. Guards: version + swarm must match, snapshot must be younger
  # than @persist_max_age_s; anything off → fresh start. A feed that restarted
  # meanwhile is caught by the normal cursor-regression re-baseline.
  @persist_vsn 1
  @persist_every_ms 30_000
  @persist_max_age_s 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Topic LiveViews subscribe to."
  def topic, do: @topic
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @doc "Threshold (s) past which the header chip treats the feed as stale."
  def stale_after_s, do: @stale_after_s

  @doc """
  Full story ring, newest first — pulled on demand by the Events page.
  Bounded + nil-safe like `current_story/0`: the feed's poll can block it for
  seconds when the swarm is slow, and a timed-out call must degrade the page,
  not crash the LiveView.
  """
  def story_ring do
    GenServer.call(__MODULE__, :story_ring, 1_000)
  catch
    :exit, _ -> []
  end

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
  def episodes(cid) do
    GenServer.call(__MODULE__, {:episodes, cid}, 1_000)
  catch
    :exit, _ -> []
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    interval = Application.get_env(:subzero_swarm_dashboard, :events_poll_ms, 700)
    swarm = Application.get_env(:subzero_swarm_dashboard, :swarm_name, "wingston")
    PubSub.subscribe(@pubsub, @snapshot_topic)
    send(self(), :poll)
    Process.send_after(self(), :persist, @persist_every_ms)

    state = %{
      interval: interval,
      swarm: swarm,
      cursor: nil,
      story: new_story(),
      feed_status: :unavailable,
      baseline_at: nil,
      # feed-anchored clock: {ts of the newest folded event, monotonic ms at arrival}
      anchor: nil,
      last_ok_mono: nil,
      # consecutive failed polls — drives the outage log (once) and backoff
      fails: 0
    }

    {:ok, restore(state)}
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
    Process.send_after(self(), :poll, poll_delay(state))
    {:noreply, state}
  end

  def handle_info(:persist, state) do
    persist(state)
    Process.send_after(self(), :persist, @persist_every_ms)
    {:noreply, state}
  end

  # /dashboard snapshot (from SwarmFeed): refresh the story's cid → @handle map so
  # event rows render the user, not the raw chat id. Snapshots arrive every few
  # seconds; storing the map is cheap and doesn't touch the cursor or the fold.
  def handle_info({:snapshot, snap}, state),
    do: {:noreply, %{state | story: Reducer.put_users(state.story, handles(snap))}}

  # other "feed" traffic (live WS events, disconnects, warnings) isn't ours to fold.
  def handle_info(_other, state), do: {:noreply, state}

  # Back off while the source is failing (700ms → 10s cap) instead of hammering
  # a down swarm; the first success resets to the base cadence. Story summaries
  # still broadcast on every poll, so pages keep their degraded chip honest.
  defp poll_delay(%{fails: 0, interval: interval}), do: interval

  defp poll_delay(%{fails: n, interval: interval}),
    do: min(interval * Integer.pow(2, min(n, 4)), 10_000)

  # the route answers but no events_source is wired host-side (old backend) —
  # a known, persistent condition: back off, but nothing to log
  defp handle_poll({:ok, %{"source" => "unavailable"}}, state),
    do: %{state | feed_status: :unavailable, fails: state.fails + 1}

  # first successful poll: baseline — keep the feed's cursor, discard history
  defp handle_poll({:ok, %{"seq" => seq}}, %{cursor: nil} = state) when is_integer(seq) do
    %{
      state
      | cursor: seq,
        feed_status: :ok,
        baseline_at: DateTime.utc_now(),
        last_ok_mono: now_mono(),
        fails: 0
    }
  end

  defp handle_poll({:ok, %{"events" => events, "seq" => seq}}, state)
       when is_list(events) and is_integer(seq) do
    if seq < state.cursor,
      do: rebaseline(state, seq),
      else: fold_batch(state, events, seq)
  end

  defp handle_poll({:ok, malformed}, state), do: degrade(state, {:malformed, malformed})
  defp handle_poll({:error, reason}, state), do: degrade(state, reason)

  # The amber "feed unavailable" chip needs a diagnosable cause: log the reason
  # ONCE per outage (fails 0 → 1), never per 700ms tick.
  defp degrade(state, reason) do
    if state.fails == 0 do
      Logger.warning(
        "events feed degraded: #{inspect(reason, limit: 5, printable_limit: 200)}"
      )
    end

    %{state | feed_status: :unavailable, fails: state.fails + 1}
  end

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
        last_ok_mono: now_mono(),
        fails: 0
    }
  end

  defp fold_batch(state, [], seq),
    do: %{state | cursor: seq, feed_status: :ok, last_ok_mono: now_mono(), fails: 0}

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
        last_ok_mono: now_mono(),
        fails: 0
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
      issues_max: Application.get_env(:subzero_swarm_dashboard, :issues_ring_max, 200),
      think_decay_ms: Application.get_env(:subzero_swarm_dashboard, :think_decay_ms, 60_000),
      wait_decay_ms: Application.get_env(:subzero_swarm_dashboard, :wait_decay_ms, 300_000),
      issue_window_s: Application.get_env(:subzero_swarm_dashboard, :issue_window_s, 86_400),
      # Seed the clock so an event missing "ts" folded before the first tick
      # can never fall through Reducer.ts/2 to 0.0 (opened_at 0.0 → the next
      # tick computes a ~56-year elapsed and instantly classifies a stall).
      now: System.os_time(:millisecond) / 1000
    )
  end

  defp now_mono, do: System.monotonic_time(:millisecond)

  @impl true
  def terminate(_reason, state), do: persist(state)

  # ── snapshot persistence ─────────────────────────────────────────────────────

  @doc "Snapshot file path (config :story_snapshot_path; default: system tmp)."
  def snapshot_path do
    Application.get_env(
      :subzero_swarm_dashboard,
      :story_snapshot_path,
      Path.join(System.tmp_dir!(), "subzero_dashboard_story.snapshot")
    )
  end

  defp persist(state) do
    # nothing worth saving before the first baseline
    if state.cursor != nil do
      payload = %{
        vsn: @persist_vsn,
        swarm: state.swarm,
        cursor: state.cursor,
        story: state.story,
        baseline_at: state.baseline_at,
        saved_at: System.os_time(:second)
      }

      path = snapshot_path()
      tmp = path <> ".tmp"
      File.write!(tmp, :erlang.term_to_binary(payload))
      File.rename!(tmp, path)
    end
  rescue
    # persistence is best-effort — a read-only disk must not take the feed down
    e -> Logger.warning("story snapshot save failed: #{Exception.message(e)}")
  end

  defp restore(state) do
    with {:ok, bin} <- File.read(snapshot_path()),
         %{vsn: @persist_vsn, swarm: swarm} = snap <- :erlang.binary_to_term(bin, [:safe]),
         true <- swarm == state.swarm or {:error, :other_swarm},
         true <-
           System.os_time(:second) - snap.saved_at <= @persist_max_age_s or
             {:error, :too_old},
         # a State struct saved by older code deserializes fine but blows up on
         # first access of a field it doesn't have — compare shapes, not luck
         true <-
           Map.keys(snap.story) == Map.keys(State.new()) or {:error, :state_shape_changed} do
      Logger.info("story restored from snapshot (cursor #{snap.cursor})")

      %{state | cursor: snap.cursor, story: snap.story, baseline_at: snap.baseline_at}
    else
      {:error, :enoent} -> state
      other ->
        Logger.warning("story snapshot ignored: #{inspect(other, limit: 3)}")
        state
    end
  rescue
    # corrupt/incompatible file (e.g. State struct changed shape) → fresh fold
    e ->
      Logger.warning("story snapshot unreadable, starting fresh: #{Exception.message(e)}")
      state
  end

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
