defmodule SubzeroSwarmDashboard.RouterClientTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!

  alias SubzeroSwarmDashboard.{RouterClient, RouterClientMock}

  test "usage/1 delegates and passes through {:ok, _}" do
    expect(RouterClientMock, :usage, fn %{} -> {:ok, %{"totals" => %{"requests" => 3}}} end)
    assert {:ok, %{"totals" => %{"requests" => 3}}} = RouterClient.usage()
  end

  test "usage/1 passes through {:unavailable, _}" do
    expect(RouterClientMock, :usage, fn _ -> {:unavailable, :not_found} end)
    assert {:unavailable, :not_found} = RouterClient.usage(%{bucket: "day"})
  end
end
