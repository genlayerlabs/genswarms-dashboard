defmodule SubzeroSwarmDashboardWeb.StoryHelpers do
  @moduledoc """
  Formatting/link helpers shared by the story-driven pages (Overview, Events,
  Session detail, Topology). Pure functions only — UI components belong in
  CoreComponents. Imported app-wide via the `html_helpers` block.
  """

  use SubzeroSwarmDashboardWeb, :verified_routes

  @doc "Session deep link — cids may carry colons (e.g. a transport's <scheme>:<id>:<sub>), so url-base64."
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

  @doc ~S(Integer/float with thousands separators — 3862856 → "3,862,856".)
  def num(n) when is_number(n) do
    n |> trunc() |> Integer.to_string() |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  def num(_), do: "0"

  @doc """
  A counter's number is only colored when it IS the alarm (nonzero) — the shared
  rule behind Overview's window panel and the Usage error tiles.
  """
  def alarm_tone(n, tone \\ "error")
  def alarm_tone(n, tone) when is_number(n) and n > 0, do: tone
  def alarm_tone(_n, _tone), do: nil

  @doc "The host's durable metrics_today extension block, or nil when absent/empty."
  def metrics_today(snap) do
    case get_in(snap || %{}, ["extensions", "metrics_today"]) do
      m when is_map(m) and map_size(m) > 0 -> m
      _ -> nil
    end
  end

  @doc """
  Join the snapshot's session → user handle (events only carry the cid); falls
  back to the label the story fold baked in.
  """
  def handle_for(snap, cid, fallback) do
    sessions = (is_map(snap) && snap["sessions"]) || []

    with %{} = s <- Enum.find(sessions, &(&1["session_id"] == cid)),
         h when is_binary(h) and h != "" <- get_in(s, ["user", "handle"]) do
      h
    else
      _ -> fallback
    end
  end
end
