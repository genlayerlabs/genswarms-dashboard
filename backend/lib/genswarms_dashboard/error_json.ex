defmodule GenswarmsDashboard.ErrorJSON do
  @moduledoc """
  Minimal JSON error view for `GenswarmsDashboard.Endpoint` (`render_errors`). The
  read API is JSON-only, so a crash/timeout that reaches the endpoint renders a
  small `{"error": "..."}` body with the status reason instead of failing a second
  time on a missing HTML/`ErrorView` template.
  """
  # template is like "404.json" / "500.json"; map it to the status reason phrase.
  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
