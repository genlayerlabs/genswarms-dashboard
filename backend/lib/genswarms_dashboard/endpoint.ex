defmodule GenswarmsDashboard.Endpoint do
  @moduledoc """
  The single network-facing surface: HTTP read-API (`GenswarmsDashboard.Plug`) + the live
  `/swarm` WS feed (`GenswarmsDashboard.Socket` → `Channel`). Config is injected at runtime
  by `GenswarmsDashboard.start/1` via `Application.put_env/3` — no compile-time config file.
  Bind IP is loopback unless a token is set (fail-closed).
  """
  use Phoenix.Endpoint, otp_app: :genswarms_dashboard

  socket("/swarm", GenswarmsDashboard.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, :uri], check_origin: false],
    longpoll: false
  )

  plug(GenswarmsDashboard.Plug)
end
