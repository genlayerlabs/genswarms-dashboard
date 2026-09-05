defmodule SubzeroSwarmDashboardWeb.ExtensionTabInputTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ExtensionPageLive

  defp socket do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, ext_tab: %{})
  end

  test "valid tab indexes preserve numeric and nested section keys" do
    for {sec, key} <- [{"0", 0}, {"0/1", "0/1"}] do
      assert {:noreply, result} =
               ExtensionPageLive.handle_event("ext_tab", %{"sec" => sec, "tab" => "2"}, socket())

      assert result.assigns.ext_tab == %{key => 2}
    end
  end

  test "malformed tab values safely select the first tab" do
    for tab <- ["abc", "", "-1", "1.5", "1\n", nil, 2, [], %{}, String.duplicate("9", 1000)] do
      assert {:noreply, result} =
               ExtensionPageLive.handle_event("ext_tab", %{"sec" => "0", "tab" => tab}, socket())

      assert result.assigns.ext_tab == %{0 => 0}
    end
  end

  test "malformed or missing sections and incomplete payloads are ignored" do
    for params <- [
          %{},
          %{"tab" => "1"},
          %{"sec" => "0"},
          %{"sec" => nil, "tab" => "1"},
          %{"sec" => %{}, "tab" => "1"},
          %{"sec" => "1\n", "tab" => "1"}
        ] do
      initial = socket()
      assert {:noreply, ^initial} = ExtensionPageLive.handle_event("ext_tab", params, initial)
    end
  end
end
