defmodule SubzeroSwarmDashboard.FleetCatalogTest do
  use ExUnit.Case, async: false

  import Mox

  alias SubzeroSwarmDashboard.{FleetCatalog, SwarmClientMock}

  setup :set_mox_global
  setup :verify_on_exit!

  test "discovers newly co-located swarms and keeps the configured root" do
    stub(SwarmClientMock, :swarms, fn ->
      {:ok, [%{"name" => "project-b"}, %{"name" => "strategivm"}]}
    end)

    start_supervised!(FleetCatalog)
    _ = :sys.get_state(FleetCatalog)

    assert FleetCatalog.current() == ["project-b", "strategivm", "wingston"]
  end
end
