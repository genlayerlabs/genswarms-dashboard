defmodule SubzeroSwarmDashboardWeb.PrivacyController do
  use SubzeroSwarmDashboardWeb, :controller

  @session_key :privacy

  def toggle(conn, _params) do
    privacy? = !enabled?(get_session(conn, @session_key))

    conn
    |> put_session(@session_key, privacy?)
    |> redirect(to: return_path(conn))
  end

  defp enabled?(true), do: true
  defp enabled?("true"), do: true
  defp enabled?(_), do: false

  defp return_path(conn) do
    conn
    |> get_req_header("referer")
    |> List.first()
    |> local_referrer(conn)
  end

  defp local_referrer(nil, _conn), do: ~p"/"
  defp local_referrer("", _conn), do: ~p"/"

  defp local_referrer(referrer, conn) do
    case URI.parse(referrer) do
      %URI{scheme: nil, host: nil, path: "/" <> _} = uri ->
        path_with_query_and_fragment(uri)

      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        if String.downcase(host) == String.downcase(conn.host) do
          path_with_query_and_fragment(uri)
        else
          ~p"/"
        end

      _ ->
        ~p"/"
    end
  end

  defp path_with_query_and_fragment(%URI{} = uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if uri.query, do: "?" <> uri.query, else: ""
    fragment = if uri.fragment, do: "#" <> uri.fragment, else: ""

    path <> query <> fragment
  end
end
