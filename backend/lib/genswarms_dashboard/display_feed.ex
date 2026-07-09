defmodule GenswarmsDashboard.DisplayFeed.Store do
  @moduledoc """
  Optional persistence adapter for `GenswarmsDashboard.DisplayFeed`.

  Hosts own the storage schema, retention, and pruning policy. The dashboard
  package only calls this behaviour to append already-normalized display events
  and to load the newest events for boot-time ring rehydrate.
  """

  @callback append_display_events([map()]) :: :ok | term()
  @callback load_recent_display_events(pos_integer()) :: [map()]
end

defmodule GenswarmsDashboard.DisplayFeed do
  @moduledoc """
  Generic display-event collector for `GenswarmsDashboard.EventsSource`.

  Hosts emit display facts on their chosen telemetry wire:

      :telemetry.execute([:my_app, :display], %{}, %{kind: :routed, cid: cid})

  `start_link/1` requires `:telemetry_event`; there is intentionally no package
  default that names a host. When the collector is running, its telemetry handler
  forwards every event as a cast, so emitters never block. The handler rescues
  and catches all failures because telemetry detaches handlers that raise.

  The single writer makes seqs GAPLESS by construction. The lock-free
  alternative -- `update_counter` then `insert` from many processes -- has a real
  race: a preempted writer can land seq N after a poller already read past N,
  silently skipping events. A gap seen by a consumer therefore proves ring
  pruning, and means "resync".

  Storage is a protected ETS ordered_set ring. Owner writes; readers call
  `since/2` or `since/3` directly. With a store module configured, the collector
  also buffers display rows into the host's store and rehydrates the newest ring
  window on boot. With `store: nil`, it remains the same ring-only collector.
  Persistence failures are contained and dropped so observability can never
  touch host routing.

  Events are maps with `seq`, `ts`, `kind`, and host-opaque fields. Kinds are
  additive; consumers must ignore unknown kinds. The package does not own an
  event-kind registry. Hosts that want a fixed vocabulary should document and
  test it in their own application.

  The dashboard backend Jason-encodes these maps verbatim. The collector is the
  JSON boundary: strings, numbers, booleans, and nil pass through; atoms become
  strings when used as values; unsupported host values become bounded strings.

  ## Cursor contract

  `since/2` returns events with `seq > since`, oldest first, plus the cursor to
  poll with next. On an empty read, the cursor is the feed's CURRENT cursor
  (highest assigned seq, 0 when the ring is empty), NEVER an echo of `since`.
  Echoing would blind a consumer across a host restart: seqs restart at 1, so an
  inflated cursor would poll a dead feed forever. Returning the real cursor makes
  the regression visible (`returned cursor < consumer cursor` means re-baseline).
  The not-running path, where no ETS table exists, still echoes because hosts
  should report their `GenswarmsDashboard.EventsSource` as `:unavailable` before
  reaching this reader.
  """

  use GenServer
  require Logger

  @default_ring 4096
  @flush_ms 2_000
  @flush_size 64
  @max_depth 4
  @max_map_entries 50
  @max_list_entries 50
  @max_string_chars 1_000
  @rehydrate_shape_keys MapSet.new([:seq, :ts, :kind])

  @type table :: atom()
  @type cursor :: non_neg_integer()

  @doc """
  Linked start for supervisors and tests.

  Options:

    * `:telemetry_event` - required telemetry event name list.
    * `:ring` - maximum ETS ring size, default `4096`.
    * `:store` - module implementing `GenswarmsDashboard.DisplayFeed.Store`, or `nil`.
    * `:flush_ms` - buffered persistence flush interval, default `2000`.
    * `:flush_size` - buffered persistence flush threshold, default `64`.
    * `:name` - registered GenServer name, default `#{inspect(__MODULE__)}`.
    * `:table` - ETS named table, default derived from `:name`.
  """
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Unlinked start for script-style hosts that fault-isolate observability."
  def start(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc """
  Events with `seq > since`, oldest first, at most `limit`. Returns
  `{events, cursor}` where `cursor` is the seq to poll with next: the last
  returned event's seq, or -- on an empty read -- the feed's CURRENT cursor
  (highest assigned seq, 0 when the ring is empty), NEVER an echo of `since`.
  """
  @spec since(cursor(), pos_integer()) :: {[map()], cursor()}
  def since(seq, limit \\ 500), do: since(default_table(__MODULE__), seq, limit)

  @doc """
  `since/2` against an explicit ETS table.

  This is useful for hosts or tests that run the collector under a non-default
  `:name`/`:table`.
  """
  @spec since(table(), cursor(), pos_integer()) :: {[map()], cursor()}
  def since(table, seq, limit) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        {[], seq}

      _ ->
        ms = [{{:"$1", :"$2"}, [{:>, :"$1", seq}], [:"$2"]}]

        events =
          case :ets.select(table, ms, max(limit, 1)) do
            {evs, _cont} -> evs
            :"$end_of_table" -> []
          end

        case List.last(events) do
          nil -> {[], current_cursor(table)}
          last -> {events, last.seq}
        end
    end
  end

  @doc "Synchronous barrier for tests: all casts already in the mailbox are processed."
  def sync(name \\ __MODULE__), do: GenServer.call(name, :sync)

  @doc false
  def handle_telemetry(_event, _measurements, meta, config) do
    GenServer.cast(config.name, {:event, meta})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    telemetry_event = fetch_telemetry_event!(opts)
    table = Keyword.get(opts, :table, default_table(name))
    ring = Keyword.get(opts, :ring, @default_ring)
    store = Keyword.get(opts, :store, nil)
    flush_ms = Keyword.get(opts, :flush_ms, @flush_ms)
    flush_size = Keyword.get(opts, :flush_size, @flush_size)

    :ets.new(table, [:ordered_set, :protected, :named_table, read_concurrency: true])

    persist? = not is_nil(store)

    {seq, rehydrated_count} =
      if persist?, do: rehydrate_from_store(store, ring, table), else: {0, 0}

    handler_id = handler_id(name, telemetry_event)
    _ = :telemetry.detach(handler_id)

    :ok =
      :telemetry.attach(handler_id, telemetry_event, &__MODULE__.handle_telemetry/4, %{name: name})

    state = %{
      seq: seq,
      table: table,
      ring: ring,
      store: store,
      persist?: persist?,
      buffer: [],
      buffer_count: 0,
      flush_ref: nil,
      flush_ms: flush_ms,
      flush_size: flush_size,
      telemetry_event: telemetry_event,
      handler_id: handler_id
    }

    state =
      if rehydrated_count > 0 do
        append_event(%{kind: :feed_rehydrated, count: rehydrated_count}, state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_cast({:event, meta}, state) when is_map(meta),
    do: {:noreply, safe_append_event(meta, state)}

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_pending(%{state | flush_ref: nil})}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :telemetry.detach(state.handler_id)
    :ok
  end

  defp default_table(name) when is_atom(name), do: :"#{name}.Table"
  defp default_table(name), do: :"#{__MODULE__}.Table.#{:erlang.phash2(name)}"

  defp handler_id(name, telemetry_event), do: {__MODULE__, name, telemetry_event}

  defp fetch_telemetry_event!(opts) do
    case Keyword.fetch(opts, :telemetry_event) do
      {:ok, event} when is_list(event) and event != [] ->
        if Enum.all?(event, &is_atom/1) do
          event
        else
          raise ArgumentError,
                "GenswarmsDashboard.DisplayFeed :telemetry_event must be a non-empty list of atoms, got: #{inspect(event)}"
        end

      :error ->
        raise ArgumentError, "GenswarmsDashboard.DisplayFeed requires :telemetry_event"

      {:ok, other} ->
        raise ArgumentError,
              "GenswarmsDashboard.DisplayFeed :telemetry_event must be a non-empty list of atoms, got: #{inspect(other)}"
    end
  end

  defp current_cursor(table) do
    case :ets.last(table) do
      :"$end_of_table" -> 0
      seq -> seq
    end
  end

  defp safe_append_event(meta, state) do
    append_event(meta, state)
  rescue
    e ->
      Logger.warning("GenswarmsDashboard.DisplayFeed: event dropped: #{Exception.message(e)}")
      state
  catch
    kind, reason ->
      Logger.warning("GenswarmsDashboard.DisplayFeed: event dropped: #{inspect({kind, reason})}")
      state
  end

  defp append_event(meta, %{seq: seq, table: table, ring: ring} = state) do
    seq = seq + 1

    event =
      meta
      |> json_safe_map()
      |> Map.put(:seq, seq)
      |> Map.put(:ts, System.system_time(:millisecond) / 1000)

    :ets.insert(table, {seq, event})
    enforce_ring_cap(table, ring)

    state
    |> Map.put(:seq, seq)
    |> maybe_buffer(event)
  end

  defp maybe_buffer(%{persist?: false} = state, _event), do: state

  defp maybe_buffer(%{persist?: true} = state, event) do
    state = %{state | buffer: [event | state.buffer], buffer_count: state.buffer_count + 1}

    if state.buffer_count >= state.flush_size do
      flush_pending(state)
    else
      schedule_flush(state)
    end
  end

  defp schedule_flush(%{flush_ref: nil, flush_ms: ms} = state) when is_integer(ms) and ms > 0,
    do: %{state | flush_ref: Process.send_after(self(), :flush, ms)}

  defp schedule_flush(state), do: state

  defp flush_pending(%{buffer_count: 0} = state),
    do: %{state | buffer: [], buffer_count: 0, flush_ref: nil}

  defp flush_pending(%{persist?: false} = state),
    do: %{state | buffer: [], buffer_count: 0, flush_ref: nil}

  defp flush_pending(%{persist?: true} = state) do
    batch = Enum.reverse(state.buffer)
    cancel_flush(state.flush_ref)

    result =
      if store_exports?(state.store, :append_display_events, 1) do
        state.store.append_display_events(batch)
      else
        {:error, :missing_append_display_events}
      end

    case result do
      :ok ->
        :ok

      nil ->
        :ok

      other ->
        Logger.warning(
          "GenswarmsDashboard.DisplayFeed: display flush dropped #{length(batch)} events: #{inspect(other)}"
        )
    end

    %{state | buffer: [], buffer_count: 0, flush_ref: nil}
  rescue
    e ->
      Logger.warning(
        "GenswarmsDashboard.DisplayFeed: display flush dropped #{length(state.buffer)} events: #{Exception.message(e)}"
      )

      %{state | buffer: [], buffer_count: 0, flush_ref: nil}
  catch
    kind, reason ->
      Logger.warning(
        "GenswarmsDashboard.DisplayFeed: display flush dropped #{length(state.buffer)} events: #{inspect({kind, reason})}"
      )

      %{state | buffer: [], buffer_count: 0, flush_ref: nil}
  end

  defp cancel_flush(nil), do: :ok

  defp cancel_flush(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp rehydrate_from_store(store, ring, table) do
    rows =
      if store_exports?(store, :load_recent_display_events, 1) do
        store.load_recent_display_events(ring)
      else
        []
      end

    events =
      case rows do
        list when is_list(list) -> list
        _ -> []
      end
      |> Enum.map(&normalize_loaded_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(-ring)

    Enum.each(events, fn event -> :ets.insert(table, {event.seq, event}) end)
    enforce_ring_cap(table, ring)

    {max_seq(events), length(events)}
  rescue
    e ->
      Logger.warning("GenswarmsDashboard.DisplayFeed: rehydrate failed: #{Exception.message(e)}")
      {0, 0}
  catch
    kind, reason ->
      Logger.warning(
        "GenswarmsDashboard.DisplayFeed: rehydrate failed: #{inspect({kind, reason})}"
      )

      {0, 0}
  end

  defp max_seq([]), do: 0
  defp max_seq(events), do: events |> Enum.map(& &1.seq) |> Enum.max()

  defp normalize_loaded_event(event) when is_map(event) do
    event = atomize_existing_event_keys(event)

    case Map.get(event, :seq) do
      seq when is_integer(seq) and seq > 0 -> event
      seq when is_binary(seq) -> %{event | seq: String.to_integer(seq)}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_loaded_event(_), do: nil

  defp atomize_existing_event_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {existing_atom_key(key), atomize_existing_event_value(value)}
    end)
  end

  defp atomize_existing_event_value(value) when is_map(value),
    do: atomize_existing_event_keys(value)

  defp atomize_existing_event_value(value) when is_list(value),
    do: Enum.map(value, &atomize_existing_event_value/1)

  defp atomize_existing_event_value(value), do: value

  defp existing_atom_key(key) when is_atom(key), do: key

  defp existing_atom_key(key) when is_binary(key) do
    atom = String.to_existing_atom(key)
    if MapSet.member?(@rehydrate_shape_keys, atom), do: atom, else: key
  rescue
    _ -> key
  end

  defp existing_atom_key(key), do: key

  defp enforce_ring_cap(table, ring) do
    case :ets.info(table, :size) do
      size when is_integer(size) and size > ring ->
        case :ets.first(table) do
          :"$end_of_table" -> :ok
          seq -> :ets.delete(table, seq)
        end

        enforce_ring_cap(table, ring)

      _ ->
        :ok
    end
  end

  defp store_exports?(store, fun, arity) when is_atom(store) do
    Code.ensure_loaded?(store) and function_exported?(store, fun, arity)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp store_exports?(_store, _fun, _arity), do: false

  defp json_safe_map(meta) when is_map(meta) do
    meta
    |> Enum.take(@max_map_entries)
    |> Map.new(fn {k, v} -> {json_safe_key(k), json_safe_value(v, 0)} end)
  end

  defp json_safe_key(k) when is_atom(k), do: k
  defp json_safe_key(k) when is_binary(k), do: bounded_string(k)
  defp json_safe_key(k), do: bounded_inspect(k)

  defp json_safe_value(v, _depth) when is_binary(v), do: bounded_string(v)
  defp json_safe_value(v, _depth) when is_integer(v) or is_boolean(v) or is_nil(v), do: v

  defp json_safe_value(v, _depth) when is_float(v),
    do: if(json_encodable?(v), do: v, else: bounded_inspect(v))

  defp json_safe_value(v, _depth) when is_atom(v), do: Atom.to_string(v)

  defp json_safe_value(%DateTime{} = v, _depth), do: DateTime.to_iso8601(v)
  defp json_safe_value(%NaiveDateTime{} = v, _depth), do: NaiveDateTime.to_iso8601(v)
  defp json_safe_value(%Date{} = v, _depth), do: Date.to_iso8601(v)
  defp json_safe_value(%Time{} = v, _depth), do: Time.to_iso8601(v)
  defp json_safe_value(%{__struct__: _} = v, _depth), do: bounded_inspect(v)

  defp json_safe_value(v, depth) when is_list(v) do
    if depth >= @max_depth do
      bounded_inspect(v)
    else
      v
      |> Enum.take(@max_list_entries)
      |> Enum.map(&json_safe_value(&1, depth + 1))
    end
  end

  defp json_safe_value(v, depth) when is_map(v) do
    if depth >= @max_depth do
      bounded_inspect(v)
    else
      v
      |> Enum.take(@max_map_entries)
      |> Map.new(fn {k, value} -> {json_safe_key(k), json_safe_value(value, depth + 1)} end)
    end
  end

  defp json_safe_value(v, _depth), do: bounded_inspect(v)

  defp bounded_string(s) do
    s = if String.valid?(s), do: s, else: inspect(s, limit: 8, printable_limit: @max_string_chars)

    if String.length(s) > @max_string_chars,
      do: String.slice(s, 0, @max_string_chars) <> " …[truncated]",
      else: s
  end

  defp json_encodable?(v) do
    match?({:ok, _}, Jason.encode(v))
  rescue
    _ -> false
  end

  defp bounded_inspect(v),
    do: v |> inspect(limit: 8, printable_limit: @max_string_chars) |> bounded_string()
end
