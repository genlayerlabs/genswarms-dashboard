defmodule SubzeroSwarmDashboardWeb.ExtensionPageGroupsTest do
  # Sidebar grouping (2026-07-27): pages may carry "group" — declared by the
  # producer or stamped by the host — and the sidebar renders a quiet header
  # per group. These pin the pure half: normalization + partitioning. The
  # layout side is a plain :for over this function's output, exercised by
  # every live test that renders the shell.
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ExtensionPages

  defp snap(pages), do: %{"extensions" => %{"dashboard_pages" => pages}}

  defp page(id, overrides \\ %{}) do
    Map.merge(%{"id" => id, "label" => id, "sections" => []}, overrides)
  end

  test "ungrouped pages stay exactly as before — first, in producer order" do
    pages = ExtensionPages.pages(snap([page("a"), page("b")]))
    {ungrouped, groups} = ExtensionPages.grouped(pages)

    assert Enum.map(ungrouped, & &1["id"]) == ["a", "b"]
    assert groups == []
  end

  test "grouped pages partition under their group, first-seen group order" do
    pages =
      ExtensionPages.pages(
        snap([
          page("proxy-router", %{"group" => "LLM"}),
          page("plain"),
          page("topups", %{"group" => "Money"}),
          page("usage-x", %{"group" => "LLM"})
        ])
      )

    {ungrouped, groups} = ExtensionPages.grouped(pages)

    assert Enum.map(ungrouped, & &1["id"]) == ["plain"]

    assert Enum.map(groups, fn {g, ps} -> {g, Enum.map(ps, & &1["id"])} end) == [
             {"LLM", ["proxy-router", "usage-x"]},
             {"Money", ["topups"]}
           ]
  end

  test "a junk group is dropped, never a crash or an empty header" do
    pages =
      ExtensionPages.pages(
        snap([
          page("a", %{"group" => "   "}),
          page("b", %{"group" => 42}),
          page("c", %{"group" => String.duplicate("x", 100)})
        ])
      )

    {ungrouped, groups} = ExtensionPages.grouped(pages)

    # blank and non-string groups fall back to ungrouped; an oversized label
    # is truncated, not rejected
    assert Enum.map(ungrouped, & &1["id"]) == ["a", "b"]
    assert [{label, [%{"id" => "c"}]}] = groups
    assert String.length(label) == 24
  end
end
