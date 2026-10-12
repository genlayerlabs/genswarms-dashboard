defmodule SubzeroSwarmDashboardWeb.ExtensionSortInputTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ExtensionPageLive

  defp socket do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, ext_sort: %{}, ext_page: %{})
  end

  test "sorting cycles asc -> desc -> off for numeric and nested section keys" do
    for {sec, key} <- [{"0", 0}, {"0/1", "0/1"}] do
      params = %{"sec" => sec, "key" => "name"}

      assert {:noreply, asc} = ExtensionPageLive.handle_event("ext_sort", params, socket())
      assert asc.assigns.ext_sort == %{key => {"name", :asc}}

      assert {:noreply, desc} = ExtensionPageLive.handle_event("ext_sort", params, asc)
      assert desc.assigns.ext_sort == %{key => {"name", :desc}}

      assert {:noreply, off} = ExtensionPageLive.handle_event("ext_sort", params, desc)
      assert off.assigns.ext_sort == %{}
    end
  end

  test "malformed sections and incomplete payloads are ignored" do
    for params <- [
          %{},
          %{"key" => "name"},
          %{"sec" => "0"},
          %{"sec" => nil, "key" => "name"},
          %{"sec" => 7, "key" => "name"},
          %{"sec" => "1\n", "key" => "name"},
          %{"sec" => "abc", "key" => "name"},
          %{"sec" => "0/", "key" => "name"},
          %{"sec" => String.duplicate("9", 1000), "key" => "name"},
          %{"sec" => "0", "key" => nil},
          %{"sec" => "0", "key" => String.duplicate("k", 1000)}
        ] do
      initial = socket()
      assert {:noreply, ^initial} = ExtensionPageLive.handle_event("ext_sort", params, initial)
    end
  end
end
