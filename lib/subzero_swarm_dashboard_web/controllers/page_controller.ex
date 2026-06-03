defmodule SubzeroSwarmDashboardWeb.PageController do
  use SubzeroSwarmDashboardWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
