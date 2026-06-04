defmodule SubzeroSwarmDashboard.SwarmFeed.SocketTest do
  use ExUnit.Case, async: true
  alias SubzeroSwarmDashboard.SwarmFeed.Socket

  test "build_uri derives the ws scheme, trims a trailing slash, appends the path" do
    assert Socket.build_uri("http://127.0.0.1:4000", nil) == "ws://127.0.0.1:4000/swarm/websocket"
    assert Socket.build_uri("https://host/", nil) == "wss://host/swarm/websocket"
  end

  test "build_uri appends ?token= only when a token is present" do
    assert Socket.build_uri("http://h:4000", "tok") == "ws://h:4000/swarm/websocket?token=tok"
    assert Socket.build_uri("http://h:4000", "") == "ws://h:4000/swarm/websocket"
  end
end
