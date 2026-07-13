defmodule SubzeroSwarmDashboard.SessionEvidence do
  @moduledoc """
  Pure, metadata-only projection of the evidence already available on a session page.

  Compaction outcomes are accepted only from the parser's lean structured records.
  Raw bodies stay in their original LiveView assigns and are never copied here.
  """

  @type availability :: :live_slot | :sensitive_hidden | :components_only | :unavailable
  @reasons_by_event %{
    "skipped" => ~w(not_enough_groups router_declined insufficient_reduction),
    "rejected" => ~w(
      invalid_layout invalid_response invalid_contract unsafe_summary
    ),
    "failed" => ~w(allocation_failed http_failed)
  }
  @applied_fields ~w(event before_messages after_messages before_bytes after_bytes)
  @non_applied_fields ~w(event reason)
  @applied_summary_fields ~w(
    compaction_applied_source_record_index
    compaction_applied_sequence
    compaction_applied_source_record_id
  )
  @parser_source %{
    "format" => "subzeroclaw.jsonl.v2",
    "parser" => "genswarms.subzeroclaw_log.v3",
    "scope" => "log_file_snapshot",
    "integrity" => "structured_v2"
  }

  @type compaction_state ::
          :applied | :skipped | :rejected | :failed | :not_observed | :hidden | :unknown

  @spec build(keyword()) :: map()
  def build(opts) when is_list(opts) do
    turns = turns(Keyword.get(opts, :transcript))
    skills = skills(Keyword.get(opts, :skills))
    activity = activity(Keyword.get(opts, :activity))

    %{
      availability: availability(turns, skills, activity),
      turns: turns,
      skills: skills,
      activity: Map.drop(activity, [:compaction]),
      compaction: activity.compaction
    }
  end

  @doc "True only for a valid lean compaction event or parser-classified summary."
  @spec compaction_entry?(term()) :: boolean()
  def compaction_entry?(entry), do: classify_compaction_entry(entry) != :not_compaction

  @doc "Project one parser record without copying raw event or summary bodies."
  @spec classify_compaction_entry(term()) :: map() | :not_compaction
  def classify_compaction_entry(
        %{
          "entry_type" => "compaction_event",
          "integrity" => "structured_v2",
          "role" => "compact",
          "sensitive" => false,
          "content_complete" => true,
          "compaction" => payload
        } = entry
      )
      when is_map(payload) do
    with true <- parser_source?(entry),
         {:ok, event} <- compaction_payload(payload),
         {:ok, source} <- source_metadata(entry) do
      event
      |> Map.merge(source)
      |> Map.merge(%{
        kind: :structured_event,
        at: display_timestamp(entry["timestamp"]),
        integrity: :structured_v2,
        summary_available: false
      })
    else
      _ -> :not_compaction
    end
  end

  def classify_compaction_entry(%{"entry_type" => "compaction_event"}), do: :not_compaction

  def classify_compaction_entry(
        %{
          "entry_type" => "compaction_summary",
          "integrity" => "structured_v2",
          "role" => "compact_summary",
          "sensitive" => true,
          "content_complete" => true,
          "content" => content,
          "compaction_summary_matched_applied" => matched?
        } = entry
      )
      when is_binary(content) and is_boolean(matched?) do
    with true <- parser_source?(entry),
         true <- String.trim(content) != "",
         {:ok, source} <- source_metadata(entry),
         {:ok, applied_source} <- applied_summary_metadata(entry, matched?, source) do
      source
      |> Map.merge(applied_source)
      |> Map.merge(%{
        kind: :structured_summary,
        matched_applied: matched?,
        at: display_timestamp(entry["timestamp"]),
        integrity: :structured_v2
      })
    else
      _ -> :not_compaction
    end
  end

  def classify_compaction_entry(%{"entry_type" => "compaction_summary"}), do: :not_compaction
  def classify_compaction_entry(_), do: :not_compaction

  defp compaction_payload(%{"event" => "applied"} = payload) do
    with true <- exact_keys?(payload, @applied_fields),
         true <- nonnegative_integers?(Map.delete(payload, "event")),
         true <- payload["before_messages"] >= payload["after_messages"],
         true <- payload["before_bytes"] > payload["after_bytes"] do
      {:ok,
       %{
         state: :applied,
         event: "applied",
         before_messages: payload["before_messages"],
         after_messages: payload["after_messages"],
         before_bytes: payload["before_bytes"],
         after_bytes: payload["after_bytes"]
       }}
    else
      _ -> :error
    end
  end

  defp compaction_payload(%{"event" => event, "reason" => reason} = payload) do
    if reason in Map.get(@reasons_by_event, event, []) and
         exact_keys?(payload, @non_applied_fields) do
      {:ok, %{state: event_state(event), event: event, reason: reason}}
    else
      :error
    end
  end

  defp compaction_payload(_), do: :error

  defp parser_source?(%{"source" => @parser_source}), do: true
  defp parser_source?(_), do: false

  defp source_metadata(%{
         "source_record_index" => index,
         "sequence" => sequence,
         "source_record_id" => source_record_id
       })
       when is_integer(index) and index >= 1 and is_integer(sequence) and sequence >= 0 do
    with {:ok, id} <- source_record_id(source_record_id),
         true <- id.record_index == index do
      {:ok, %{source_record_index: index, sequence: sequence, source_record_id: id}}
    else
      _ -> :error
    end
  end

  defp source_metadata(_), do: :error

  defp applied_summary_metadata(entry, false, _source) do
    if Enum.all?(@applied_summary_fields, &(not Map.has_key?(entry, &1))),
      do: {:ok, %{}},
      else: :error
  end

  defp applied_summary_metadata(
         %{
           "compaction_applied_source_record_index" => index,
           "compaction_applied_sequence" => sequence,
           "compaction_applied_source_record_id" => source_record_id
         },
         true,
         source
       )
       when is_integer(index) and index >= 1 and is_integer(sequence) and sequence >= 0 do
    with {:ok, id} <- source_record_id(source_record_id),
         true <- id.record_index == index,
         true <- source.source_record_id.session_id == id.session_id,
         true <- source.source_record_index == index + 1,
         true <- source.sequence == sequence + 1 do
      {:ok,
       %{
         applied_source_record_index: index,
         applied_sequence: sequence,
         applied_source_record_id: id
       }}
    else
      _ -> :error
    end
  end

  defp applied_summary_metadata(_, true, _source), do: :error

  defp source_record_id(%{"session_id" => session_id, "record_index" => index} = id)
       when is_binary(session_id) and is_integer(index) and index >= 1 do
    if map_size(id) == 2 and String.trim(session_id) != "",
      do: {:ok, %{session_id: session_id, record_index: index}},
      else: :error
  end

  defp source_record_id(_), do: :error

  defp exact_keys?(map, fields), do: MapSet.new(Map.keys(map)) == MapSet.new(fields)

  defp nonnegative_integers?(map),
    do: Enum.all?(map, fn {_key, value} -> is_integer(value) and value >= 0 end)

  defp event_state("skipped"), do: :skipped
  defp event_state("rejected"), do: :rejected
  defp event_state("failed"), do: :failed

  defp turns({:ok, %{"source" => "unavailable"}}),
    do: %{state: :unavailable, count: 0, source: "unavailable"}

  defp turns({:ok, %{"turns" => turns, "source" => source}}) when is_list(turns) do
    state = if turns == [], do: :empty, else: :available
    %{state: state, count: length(turns), source: source}
  end

  defp turns(:hidden), do: %{state: :hidden, count: 0, source: nil}
  defp turns(:loading), do: %{state: :loading, count: 0, source: nil}
  defp turns(_), do: %{state: :unavailable, count: 0, source: nil}

  defp skills({:ok, %{"source" => "unavailable"}}),
    do: %{state: :unavailable, count: 0, bytes: 0, source: "unavailable"}

  defp skills({:ok, %{"skills" => skills, "source" => source}}) when is_list(skills) do
    %{
      state: skill_state(source, skills),
      count: length(skills),
      bytes: Enum.reduce(skills, 0, &skill_bytes/2),
      source: source
    }
  end

  defp skills(:loading), do: %{state: :loading, count: 0, bytes: 0, source: nil}
  defp skills(_), do: %{state: :unavailable, count: 0, bytes: 0, source: nil}

  defp skill_state("slot", _skills), do: :slot
  defp skill_state("pool", _skills), do: :pool
  defp skill_state(_source, []), do: :empty
  defp skill_state(_source, _skills), do: :available

  defp skill_bytes(%{"content" => content}, acc) when is_binary(content),
    do: acc + byte_size(content)

  defp skill_bytes(_, acc), do: acc

  defp activity({:ok, %{"logs" => logs, "source" => "slot"}}) when is_list(logs) do
    %{state: :slot, count: length(logs), source: "slot", compaction: compaction(logs)}
  end

  defp activity(:hidden),
    do: %{state: :hidden, count: 0, source: nil, compaction: hidden_compaction()}

  defp activity(:loading),
    do: %{state: :loading, count: 0, source: nil, compaction: unknown_compaction()}

  defp activity(_),
    do: %{state: :unavailable, count: 0, source: nil, compaction: unknown_compaction()}

  defp compaction(logs) do
    classified = Enum.map(logs, &classify_compaction_entry/1)

    case classified |> Enum.filter(&match?(%{kind: :structured_event}, &1)) |> List.last() do
      %{} = event ->
        event
        |> Map.put(:summary_available, matching_summary?(classified, event))
        |> Map.drop([:kind, :source_record_id, :sequence])

      nil ->
        not_observed_compaction()
    end
  end

  defp matching_summary?(classified, %{state: :applied} = event) do
    Enum.any?(classified, fn
      %{
        kind: :structured_summary,
        matched_applied: true,
        applied_source_record_index: index,
        applied_sequence: sequence,
        applied_source_record_id: source_record_id
      } ->
        index == event.source_record_index and sequence == event.sequence and
          source_record_id == event.source_record_id

      _ ->
        false
    end)
  end

  defp matching_summary?(_classified, _event), do: false

  defp display_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp display_timestamp(_), do: nil

  defp not_observed_compaction,
    do: %{state: :not_observed, at: nil, summary_available: false}

  defp unknown_compaction, do: %{state: :unknown, at: nil, summary_available: false}
  defp hidden_compaction, do: %{state: :hidden, at: nil, summary_available: false}

  defp availability(_turns, _skills, %{state: :slot}), do: :live_slot
  defp availability(_turns, _skills, %{state: :hidden}), do: :sensitive_hidden

  defp availability(turns, skills, _activity) do
    if component_available?(turns) or component_available?(skills),
      do: :components_only,
      else: :unavailable
  end

  defp component_available?(%{state: state}),
    do: state in [:available, :empty, :slot, :pool]
end
