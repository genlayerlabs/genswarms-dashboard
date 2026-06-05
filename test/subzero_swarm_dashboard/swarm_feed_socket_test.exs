defmodule SubzeroSwarmDashboard.SwarmFeed.SocketTest do
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboard.SwarmFeed.Socket

  test "build_uri derives the ws scheme, trims a trailing slash, appends the path" do
    assert Socket.build_uri("http://127.0.0.1:4000") == "ws://127.0.0.1:4000/swarm/websocket"
    assert Socket.build_uri("https://host/") == "wss://host/swarm/websocket"
  end

  test "build_uri NEVER carries the token in the URL (it's a header now)" do
    # regression guard: the secret must not leak into the ws URL / logs.
    refute Socket.build_uri("http://h:4000") =~ "token"
  end

  test "auth_headers carries the read token as x-dashboard-token, or [] when unset" do
    assert Socket.auth_headers("tok") == [{"x-dashboard-token", "tok"}]
    assert Socket.auth_headers(nil) == []
    assert Socket.auth_headers("") == []
  end
end
