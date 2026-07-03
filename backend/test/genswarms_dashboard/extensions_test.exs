defmodule GenswarmsDashboard.ExtensionsTest do
  use ExUnit.Case, async: true

  alias GenswarmsDashboard.Extensions

  defmodule GoodProvider do
    def dashboard_extension(opts) do
      %{
        "good" => %{"day" => Keyword.get(opts, :day, "?")},
        "dashboard_pages" => [%{"id" => "good", "label" => "Good", "sections" => []}]
      }
    end
  end

  defmodule RaisingProvider do
    def dashboard_extension(_opts), do: raise("boom")
  end

  test "collect merges module + map providers; pages concat, first id wins" do
    ready = %{
      "ready" => %{"x" => 1},
      "dashboard_pages" => [
        %{"id" => "ready", "label" => "Ready", "sections" => []},
        # duplicate id with the module provider — the FIRST occurrence wins
        %{"id" => "good", "label" => "Impostor", "sections" => []}
      ]
    }

    ext = Extensions.collect([GoodProvider, ready], day: "2026-07-03")

    assert ext["good"] == %{"day" => "2026-07-03"}
    assert ext["ready"] == %{"x" => 1}
    assert Enum.map(ext["dashboard_pages"], & &1["id"]) == ["good", "ready"]
    assert Enum.find(ext["dashboard_pages"], &(&1["id"] == "good"))["label"] == "Good"
  end

  test "a raising, missing, or non-exporting provider contributes nothing (fail-open)" do
    ext = Extensions.collect([RaisingProvider, :definitely_not_a_loaded_module, Enum, %{"k" => %{}}])
    # collect never MANUFACTURES keys: zero contributed pages => no pages key.
    assert Map.keys(ext) == ["k"]
    refute Map.has_key?(ext, "dashboard_pages")
  end

  test "schema/0 names the contract version" do
    assert Extensions.schema() == 1
  end
end
