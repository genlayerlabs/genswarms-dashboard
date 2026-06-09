defmodule GenswarmsDashboard.Socket do
  @moduledoc """
  Phoenix socket transport for the dashboard's live feed. FAIL-CLOSED, matching the HTTP plug:

    * token nil (Config) → the endpoint binds 127.0.0.1 only; locality is the gate.
    * token set → every WS upgrade must carry it: `x-dashboard-token` header (what the
      dashboard's Slipstream client sends), `Authorization: Bearer`, or `?token=`.
      Compared with `Plug.Crypto.secure_compare` (constant time).
  """
  use Phoenix.Socket

  channel("swarm:*", GenswarmsDashboard.Channel)

  @impl true
  def connect(_params, socket, connect_info) do
    case GenswarmsDashboard.Config.get(:token) do
      nil -> {:ok, socket}
      token -> if authorized?(connect_info, token), do: {:ok, socket}, else: :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp authorized?(connect_info, token) do
    provided = header(connect_info, "x-dashboard-token") || bearer(connect_info) || query_token(connect_info)
    is_binary(provided) and provided != "" and Plug.Crypto.secure_compare(provided, token)
  end

  defp header(%{x_headers: headers}, key) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == key, do: v end)
  end

  defp header(_, _), do: nil

  defp bearer(connect_info) do
    case header(connect_info, "authorization") do
      "Bearer " <> t -> t
      _ -> nil
    end
  end

  defp query_token(%{uri: %URI{query: q}}) when is_binary(q), do: URI.decode_query(q)["token"]
  defp query_token(_), do: nil
end
