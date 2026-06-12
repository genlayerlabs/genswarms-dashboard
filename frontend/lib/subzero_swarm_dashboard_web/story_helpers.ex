defmodule SubzeroSwarmDashboardWeb.StoryHelpers do
  @moduledoc """
  Formatting/link helpers shared by the story-driven pages (Overview, Events,
  Session detail, Topology). Pure functions only — UI components belong in
  CoreComponents. Imported app-wide via the `html_helpers` block.
  """

  use SubzeroSwarmDashboardWeb, :verified_routes

  @doc "Session deep link — cids carry colons (tg:<chat>:<thread>), so url-base64."
  def session_href(cid), do: ~p"/sessions/#{Base.url_encode64(cid, padding: false)}"

  @doc "HH:MM from a DateTime or unix ts — the story honesty-label format."
  def hhmm(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  def hhmm(ts) when is_number(ts),
    do: ts |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%H:%M")

  def hhmm(_), do: "—"

  @doc "HH:MM:SS from a unix ts — story-row timestamps."
  def hms(ts) when is_number(ts),
    do: ts |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%H:%M:%S")

  def hms(_), do: "—"

  @doc "Bare one-decimal seconds, no unit — for callers composing their own suffix."
  def sec(v) when is_number(v), do: :erlang.float_to_binary(v / 1, decimals: 1)
  def sec(_), do: "—"

  @doc "Human duration: `9.2s` under a minute, `1m 23s` from there."
  def duration(s) when is_number(s) and s < 60, do: "#{sec(s)}s"
  def duration(s) when is_number(s), do: "#{div(trunc(s), 60)}m #{rem(trunc(s), 60)}s"
  def duration(_), do: "—"
end
