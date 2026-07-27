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

  test "sidebar_plan slots builtin groups (case-insensitive), keeps extra sections in order" do
    plan =
      ExtensionPages.sidebar_plan(
        snap([
          page("telegram", %{"group" => "swarm"}),
          page("proxy-router", %{"group" => "LLM"}),
          page("topups", %{"group" => "Money"}),
          page("plain"),
          page("cron-jobs", %{"group" => "System"}),
          page("growth", %{"group" => "Engagement"})
        ])
      )

    assert Enum.map(plan.builtin["swarm"], & &1["id"]) == ["telegram"]
    assert Enum.map(plan.builtin["llm"], & &1["id"]) == ["proxy-router"]
    assert Enum.map(plan.builtin["system"], & &1["id"]) == ["cron-jobs"]

    assert Enum.map(plan.extra, fn {g, ps} -> {g, Enum.map(ps, & &1["id"])} end) == [
             {"Money", ["topups"]},
             {"Engagement", ["growth"]}
           ]

    assert Enum.map(plan.ungrouped, & &1["id"]) == ["plain"]
  end

  test "icons: known names pass, unknown/runtime-only names get the visible fallback" do
    [known, unknown] =
      ExtensionPages.pages(
        snap([
          page("a", %{"icon" => "hero-credit-card"}),
          page("b", %{"icon" => "hero-made-up-at-runtime"})
        ])
      )

    assert known["icon"] == "hero-credit-card"
    # a name Tailwind never generated a class for must NOT reach the DOM —
    # it renders as an invisible blank (the 2026-07-27 mixed-column sidebar)
    assert unknown["icon"] == "hero-puzzle-piece"
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
