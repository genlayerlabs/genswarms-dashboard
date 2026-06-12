defmodule SubzeroSwarmDashboardWeb.UsageLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.RouterClient

  # Selectable look-back windows → seconds (nil = all recorded). Passed to the
  # router as a unix `since` (the v2 usage endpoint accepts since/until/bucket).
  @windows %{"1h" => 3_600, "24h" => 86_400, "7d" => 604_800, "all" => nil}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load)
    {:ok, assign(socket, page_title: "Usage", usage: :loading, range: "all")}
  end

  @impl true
  def handle_info(:load, socket) do
    {:noreply, assign(socket, usage: RouterClient.usage(range_opts(socket.assigns.range)))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("range", %{"window" => w}, socket) when is_map_key(@windows, w) do
    send(self(), :load)
    {:noreply, assign(socket, range: w, usage: :loading)}
  end

  def handle_event("range", _params, socket), do: {:noreply, socket}

  # Build the request opts for the selected window. "all" → no bound.
  defp range_opts("all"), do: %{}
  defp range_opts(w), do: %{since: System.os_time(:second) - Map.fetch!(@windows, w)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:usage}
      swarm={@swarm}
      story={@story}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-5 max-w-5xl">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h1 class="text-2xl">
            Usage
            <span class="text-xs opacity-50 font-sans align-middle">
              LLM tokens · latency · health (router)
            </span>
          </h1>
          <div class="join">
            <button
              :for={w <- ~w(1h 24h 7d all)}
              class={["btn btn-xs join-item", (@range == w && "btn-primary") || "btn-ghost"]}
              phx-click="range"
              phx-value-window={w}
            >
              {w}
            </button>
          </div>
        </div>
        <.wingston story={@story} snapshot={@snapshot} />
        <.usage usage={@usage} />
      </div>
    </Layouts.app>
    """
  end

  # ── wingston (bot) counters ─────────────────────────────────────────────────
  attr :story, :any, default: nil
  attr :snapshot, :any, default: nil

  # The bot's own activity (spec §5.6 Usage): since-baseline story KPIs, upgraded
  # per-counter to the host's durable daily values when the snapshot publishes
  # extensions["metrics_today"] (§6.3). The router/LLM cards below are untouched.
  defp wingston(assigns) do
    kpis = (assigns.story || %{})[:kpis] || %{}
    today = metrics_today(assigns.snapshot)
    since = since_label(assigns.story)
    {browse_ok, browse_total, browse_src} = browse_counts(today, kpis)

    assigns =
      assign(assigns,
        today: today,
        stats: [
          counter_stat("Replies", today, "replies", kpis[:replies], since),
          %{
            label: "Browse ok",
            value: ok_rate(browse_ok, browse_total),
            sub: "#{num(browse_ok)}/#{num(browse_total)} · #{browse_src || since}"
          },
          counter_stat("Asks", today, "asks", kpis[:asks], since),
          counter_stat("Compactions", today, "compactions", kpis[:compactions], since)
        ]
      )

    ~H"""
    <div :if={@story || @today} id="wingston-usage" class="space-y-2">
      <h2 class="font-semibold">
        Wingston
        <span class="text-xs opacity-50 font-normal">
          replies · browse · asks · compactions (bot)
        </span>
      </h2>
      <%= if @today || (@story && @story[:baseline_at]) do %>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.stat :for={s <- @stats} label={s.label} value={s.value} sub={s.sub} />
        </div>
      <% else %>
        <p class="text-sm opacity-60">
          Event feed unavailable — bot counters resume when it answers. Router usage below is unaffected.
        </p>
      <% end %>
    </div>
    """
  end

  # One counter card: the durable daily value when the host publishes it
  # ("today"), else the story's since-baseline counter — each labeled by its
  # source so a card never implies a window it can't back.
  defp counter_stat(label, today, key, fallback, since) do
    case (today || %{})[key] do
      n when is_number(n) -> %{label: label, value: num(n), sub: "today"}
      _ -> %{label: label, value: num(fallback), sub: since}
    end
  end

  defp browse_counts(today, kpis) do
    case {(today || %{})["browse_ok"], (today || %{})["browse_total"]} do
      {ok, total} when is_number(ok) and is_number(total) -> {ok, total, "today"}
      _ -> {kpis[:browse_ok] || 0, kpis[:browse_total] || 0, nil}
    end
  end

  defp ok_rate(ok, total) when is_number(ok) and is_number(total) and total > 0,
    do: "#{round(ok * 100 / total)}%"

  defp ok_rate(_, _), do: "—"

  defp metrics_today(snap) do
    case get_in(snap || %{}, ["extensions", "metrics_today"]) do
      m when is_map(m) and map_size(m) > 0 -> m
      _ -> nil
    end
  end

  defp since_label(%{baseline_at: %DateTime{} = dt}),
    do: "since #{Calendar.strftime(dt, "%H:%M")}"

  defp since_label(_story), do: "since baseline"

  attr :usage, :any, required: true

  defp usage(%{usage: {:ok, u}} = assigns) do
    totals = u["totals"] || %{}

    assigns =
      assign(assigns,
        totals: totals,
        health: u["health_summary"] || %{},
        settings: u["consumer_settings"] || %{},
        key: u["key"] || %{},
        route_health: u["route_health"] || [],
        recent: u["recent"] || [],
        security: u["security"] || %{},
        breakdowns: [
          {"By served model", "model", breakdown_rows(u["by_served_model"])},
          {"By provider", "provider", breakdown_rows(u["by_provider"])},
          {"By route", "route", breakdown_rows(u["by_route"])},
          {"By model family", "family", breakdown_rows(u["by_model_family"])}
        ],
        stale?: u["detail_level"] not in ["full", nil]
      )

    ~H"""
    <div :if={@stale?} class="alert alert-warning text-sm">
      Limited detail (<code>detail_level: {@usage |> elem(1) |> Map.get("detail_level")}</code>) — this key may not be a router consumer.
    </div>

    <div class="grid grid-cols-2 lg:grid-cols-5 gap-4">
      <.stat label="Requests" value={num(@totals["requests"])} />
      <.stat
        label="Tokens"
        value={num(@totals["tokens_total"])}
        sub={"#{num(@totals["tokens_in"])} in · #{num(@totals["tokens_out"])} out"}
      />
      <.stat
        label="Error rate"
        value={pct(@totals["error_rate"])}
        sub={"#{num(@totals["errors"])} errors"}
      />
      <.stat
        label="Latency"
        value={ms(@totals["latency_ms_avg"])}
        sub={"max #{ms(@totals["latency_ms_max"])}"}
      />
      <.stat label="Last seen" value={rel_unix(@totals["last_seen"])} />
    </div>

    <div class="grid lg:grid-cols-3 gap-4">
      <div class="card bg-base-200 p-4 lg:col-span-2">
        <h2 class="font-semibold mb-2">Health</h2>
        <div class="flex flex-wrap items-center gap-2 mb-3">
          <span class={["badge", health_badge(@health["state"])]}>
            {@health["state"] || "unknown"}
          </span>
          <span class="badge badge-ghost">success {pct(@health["success_rate"])}</span>
          <span class="badge badge-ghost">
            {num(@health["success_count"])}/{num(@health["request_count"])} ok
          </span>
          <span :if={(@health["route_failures"] || 0) > 0} class="badge badge-warning">
            {@health["route_failures"]} route failures
          </span>
        </div>
        <div class="flex flex-wrap gap-1.5">
          <span
            :for={{code, n} <- status_rows(@health["status_counts"])}
            class={["badge badge-sm", status_badge(code)]}
          >
            {code}: {num(n)}
          </span>
        </div>
        <div :if={@route_health != []} class="mt-3 border-t border-base-300 pt-3 space-y-1">
          <div :for={r <- @route_health} class="flex items-center gap-2 text-sm">
            <span class={["badge badge-xs", health_badge(r["state"])]}>{r["state"]}</span>
            <span class="font-mono text-xs">{r["route"]}</span>
            <span :if={r["served_model_id"]} class="opacity-60 text-xs">
              → {r["served_model_id"]}
            </span>
          </div>
        </div>
      </div>

      <div class="card bg-base-200 p-4">
        <h2 class="font-semibold mb-2">Your key</h2>
        <dl class="grid grid-cols-3 gap-x-2 gap-y-1.5 text-sm">
          <dt class="opacity-50">status</dt>
          <dd class="col-span-2">
            <span class={["badge badge-sm", status_word_badge(@settings["status"] || @key["status"])]}>
              {@settings["status"] || @key["status"] || "—"}
            </span>
          </dd>
          <dt class="opacity-50">key</dt>
          <dd class="col-span-2 font-mono text-xs break-all">{@key["sha256_prefix"] || "—"}…</dd>
          <dt class="opacity-50">rate</dt>
          <dd class="col-span-2 tnum">{rate_str(@settings)}</dd>
          <dt class="opacity-50">routes</dt>
          <dd class="col-span-2">{routes_str(@settings["allowed_routes"])}</dd>
        </dl>
      </div>
    </div>

    <div class="grid lg:grid-cols-2 gap-4">
      <.breakdown :for={{title, head, rows} <- @breakdowns} title={title} head={head} rows={rows} />
    </div>

    <div class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">Recent requests</h2>
      <p class="text-xs opacity-50 mb-2">Sanitized — no request/response bodies, no secrets.</p>
      <.recent rows={@recent} />
    </div>

    <p class="text-xs opacity-40">
      schema v{@usage |> elem(1) |> Map.get("schema_version")} · {(@security["sanitized"] &&
                                                                     "sanitized") || "unsanitized"} ·
      no raw key / digest / provider creds exposed
    </p>
    """
  end

  defp usage(%{usage: :loading} = assigns) do
    ~H"""
    <div class="opacity-60">loading…</div>
    """
  end

  defp usage(assigns) do
    ~H"""
    <div class="card bg-base-200 p-6 text-center">
      <div class="text-lg font-semibold">Usage unavailable</div>
      <div class="text-sm opacity-60 mt-1">
        The router's <code>/v1/usage</code> endpoint isn't configured or returned an error
        (set <code>ROUTER_USAGE_URL</code> + <code>ROUTER_API_KEY</code>).
      </div>
    </div>
    """
  end

  # ── breakdown table (one per dimension) ─────────────────────────────────────
  attr :title, :string, required: true
  attr :head, :string, required: true
  attr :rows, :list, required: true

  defp breakdown(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <h2 class="font-semibold mb-2">{@title}</h2>
      <table :if={@rows != []} class="table table-xs">
        <thead>
          <tr>
            <th>{@head}</th>
            <th class="text-right">req</th>
            <th class="text-right">tokens</th>
            <th class="text-right">err</th>
            <th class="text-right">lat avg/max</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{name, s} <- @rows}>
            <td class="font-mono text-xs break-all">{name}</td>
            <td class="text-right tnum">{num(s["requests"])}</td>
            <td class="text-right tnum">{num(s["tokens_total"])}</td>
            <td class="text-right tnum">{pct(s["error_rate"])}</td>
            <td class="text-right tnum text-xs">
              {ms(s["latency_ms_avg"])} / {ms(s["latency_ms_max"])}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@rows == []} class="text-sm opacity-50">No data.</div>
    </div>
    """
  end

  # ── recent request rows ─────────────────────────────────────────────────────
  attr :rows, :list, required: true

  defp recent(%{rows: []} = assigns) do
    ~H"""
    <div class="text-sm opacity-50">No recent requests recorded.</div>
    """
  end

  defp recent(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-xs">
        <thead>
          <tr>
            <th>when</th>
            <th>status</th>
            <th>model</th>
            <th>route</th>
            <th class="text-right">lat</th>
            <th class="text-right">tokens</th>
            <th>detail</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows}>
            <td class="tnum text-xs" title={r["ts"]}>{rel_unix(r["ts"])}</td>
            <td><span class={["badge badge-xs", status_badge(r["status"])]}>{r["status"]}</span></td>
            <td class="font-mono text-xs">{r["served_model_id"] || r["requested_model"] || "—"}</td>
            <td class="font-mono text-xs opacity-70">{r["path"] || "—"}</td>
            <td class="text-right tnum text-xs">{ms(r["latency_ms"])}</td>
            <td class="text-right tnum text-xs">{num(r["tokens_total"])}</td>
            <td class="text-xs opacity-70 max-w-xs truncate">{recent_detail(r)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # An error message wins; else a compact decision trace if the router recorded one.
  defp recent_detail(%{"error_message" => m}) when is_binary(m) and m != "", do: m
  defp recent_detail(%{"error_type" => t}) when is_binary(t) and t != "", do: t
  defp recent_detail(%{"decision_trace" => t}) when not is_nil(t), do: inspect(t)
  defp recent_detail(_), do: ""

  # ── stat card ───────────────────────────────────────────────────────────────
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="text-xs uppercase opacity-60">{@label}</div>
      <div class="text-2xl font-bold tnum">{@value}</div>
      <div :if={@sub} class="text-xs opacity-50 mt-0.5">{@sub}</div>
    </div>
    """
  end

  # ── formatting / shaping helpers ────────────────────────────────────────────

  # A breakdown map (%{name => stats}) → list sorted by requests desc.
  defp breakdown_rows(map) when is_map(map),
    do: Enum.sort_by(map, fn {_k, s} -> -(s["requests"] || 0) end)

  defp breakdown_rows(_), do: []

  # status_counts is a %{"200" => n}; render in code order.
  defp status_rows(map) when is_map(map),
    do: Enum.sort_by(map, fn {code, _} -> to_string(code) end)

  defp status_rows(_), do: []

  defp rate_str(%{"effective_per_min" => e} = s) when is_integer(e),
    do: "#{e}/min" <> if(s["burst"], do: " · burst #{s["burst"]}", else: "")

  defp rate_str(%{"rate_per_min" => r}) when is_integer(r), do: "#{r}/min"
  defp rate_str(_), do: "—"

  defp routes_str([]), do: "all"
  defp routes_str(list) when is_list(list) and list != [], do: Enum.join(list, ", ")
  defp routes_str(_), do: "all"

  # Integer/float with thousands separators ("3100000" → "3,100,000").
  defp num(n) when is_number(n) do
    n |> trunc() |> Integer.to_string() |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp num(_), do: "0"

  # error_rate / success_rate are 0..1 floats → percent.
  defp pct(r) when is_number(r), do: "#{Float.round(r * 100.0, 2)}%"
  defp pct(_), do: "0%"

  defp ms(v) when is_number(v), do: "#{round(v)} ms"
  defp ms(_), do: "—"

  # Relative time from a unix-seconds timestamp.
  defp rel_unix(ts) when is_integer(ts) and ts > 0 do
    diff = System.os_time(:second) - ts

    cond do
      diff < 0 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp rel_unix(_), do: "—"

  defp health_badge("healthy"), do: "badge-success"
  defp health_badge("degraded"), do: "badge-warning"
  defp health_badge(s) when s in ["down", "failing", "unhealthy"], do: "badge-error"
  defp health_badge(_), do: "badge-ghost"

  defp status_word_badge("active"), do: "badge-success"
  defp status_word_badge(s) when s in ["disabled", "revoked", "blocked"], do: "badge-error"
  defp status_word_badge(_), do: "badge-ghost"

  defp status_badge(code) do
    case code |> to_string() |> Integer.parse() do
      {n, _} when n >= 500 -> "badge-error"
      {n, _} when n >= 400 -> "badge-warning"
      {n, _} when n >= 200 and n < 300 -> "badge-success"
      _ -> "badge-ghost"
    end
  end
end
