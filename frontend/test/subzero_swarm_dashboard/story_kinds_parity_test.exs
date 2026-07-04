defmodule SubzeroSwarmDashboard.Story.KindsParityTest do
  @moduledoc """
  The vocabulary police. The display-event kinds live in several hand-maintained
  layers; three shipped incidents came from one layer drifting behind a change
  in another. These tests pin every layer to `Story.Kinds` — add a kind there
  and each assertion tells you exactly which layer still lags.
  """
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.Story.{Kinds, Reducer, State}

  @pipeline_js Path.expand("../../assets/js/hooks/pipeline.js", __DIR__)

  defp fold_sample(kind, meta) do
    pre = Map.get(meta, :pre, [])
    state = Enum.reduce(pre, State.new(), &Reducer.apply(&2, &1))
    ev = Map.merge(%{"kind" => kind, "seq" => 1, "ts" => 100.0}, meta.sample)
    {Reducer.apply(state, ev), length(state.story)}
  end

  describe "reducer parity" do
    test "every story wire kind folds to a REAL row (not the unknown-kind fallback)" do
      for {kind, %{story: true} = meta} <- Kinds.wire() do
        {state, pre_rows} = fold_sample(kind, meta)

        assert length(state.story) == pre_rows + 1,
               "#{kind}: expected exactly one NEW story row from its sample, " <>
                 "got #{length(state.story) - pre_rows}"

        [row | _] = state.story
        assert row.kind == kind, "#{kind}: row baked kind #{inspect(row.kind)}"

        refute String.starts_with?(row.text, "· "),
               "#{kind}: hit the generic unknown-kind fold — its clause is gone " <>
                 "or the sample lost a required field (text: #{inspect(row.text)})"
      end
    end

    test "every silent wire kind folds to NO row (canvas-only by design)" do
      for {kind, %{story: false} = meta} <- Kinds.wire() do
        {state, pre_rows} = fold_sample(kind, meta)
        assert length(state.story) == pre_rows, "#{kind}: registered story-silent but baked a row"
      end
    end

    test "folded synthetics behave like story wire kinds" do
      for {kind, meta} <- Kinds.folded_synthetic() do
        {state, _} = fold_sample(kind, meta)
        assert [%{kind: ^kind} = row] = state.story
        refute String.starts_with?(row.text, "· "), "#{kind}: generic fold"
      end
    end

    test "tick synthetics really are produced by tick (registry stays honest)" do
      # stalled: an open episode past the threshold; abandoned: far past it
      state =
        State.new(stall_after_ms: 5_000)
        |> Reducer.apply(%{"kind" => "request_open", "cid" => "tg:1:0", "seq" => 1, "ts" => 100.0})

      stalled = Reducer.tick(state, 110.0)
      abandoned = Reducer.tick(stalled, 151.0)
      produced = Enum.map(abandoned.story, & &1.kind)

      for kind <- Kinds.tick_synthetic() do
        assert kind in produced, "#{kind}: registered as tick-synthetic but tick never produced it"
      end
    end
  end

  describe "events filter parity" do
    test "the filter list is exactly the rows the reducer can bake" do
      # by construction (@kinds derives from the registry) — this guards the
      # construction itself against being reverted to a hand list
      assert Kinds.filter_kinds() ==
               for({k, %{story: true}} <- Kinds.wire(), do: k) ++
                 Kinds.tick_synthetic() ++ for({k, _} <- Kinds.folded_synthetic(), do: k)
    end
  end

  describe "canvas parity (the browse→browser incident, generalized)" do
    test "pipeline.js mentions every canvas-visible kind" do
      js = File.read!(@pipeline_js)

      for kind <- Kinds.canvas_kinds() do
        assert js =~ ~s("#{kind}"),
               "#{kind}: registered canvas: true but pipeline.js never mentions it — " <>
                 "add a case arm (or an intake normalization) or flip the registry to canvas: false"
      end
    end
  end
end
