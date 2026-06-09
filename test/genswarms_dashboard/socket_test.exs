defmodule GenswarmsDashboard.SocketTest do
  use ExUnit.Case, async: false
  alias GenswarmsDashboard.{Config, Socket}

  setup do
    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :config) end)
  end

  defp connect(info), do: Socket.connect(%{}, :fake_socket, info)

  test "no token configured ⇒ connect succeeds (loopback bind is the gate)" do
    Config.put(%{token: nil})
    assert {:ok, :fake_socket} = connect(%{})
  end

  test "token: x-dashboard-token header (the dashboard's transport) is accepted" do
    Config.put(%{token: "s3cret"})
    assert {:ok, _} = connect(%{x_headers: [{"x-dashboard-token", "s3cret"}]})
  end

  test "token: Bearer and ?token= are accepted; wrong/missing are rejected" do
    Config.put(%{token: "s3cret"})
    assert {:ok, _} = connect(%{x_headers: [{"authorization", "Bearer s3cret"}]})
    assert {:ok, _} = connect(%{uri: %URI{query: "token=s3cret"}})
    assert :error = connect(%{x_headers: [{"x-dashboard-token", "nope"}]})
    assert :error = connect(%{})
    assert :error = connect(%{uri: %URI{query: "token="}})
  end
end
