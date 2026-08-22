defmodule SubzeroSwarmDashboardWeb.TopologyLive do
  use SubzeroSwarmDashboardWeb, :live_view

  alias SubzeroSwarmDashboard.PrivacyRedactor
  alias SubzeroSwarmDashboardWeb.CoreComponents
  alias SubzeroSwarmDashboardWeb.DashHooks

  # Band geometry (canvas fractions): services row(s) hang from the top edge,
  # bookkeeping row(s) rise from the bottom. The agent grid gets per-side
  # extents derived from each band's innermost occupied row, so a deep band on
  # one side pushes the grid toward the other instead of shrinking it in place.
  @band_row_max 7
  @band_row_step 0.11
  @band_top_y 0.12
  @band_bottom_y 0.88
  # innermost band row -> grid edge breathing room (chip half-height + air)
  @band_clearance 0.07
  # grid extents when a side has no band (matches the legacy 0.66 span look)
  @agent_y_min_default 0.17
  @agent_y_max_default 0.83

  @impl true
  def mount(_params, _session, socket) do
    snap = socket.assigns[:snapshot]
    socket = assign(socket, :topo_expanded, MapSet.new())
    layout = pipeline_layout(snap)

    # A cached snapshot at mount must seed the hook's agent grid too —
    # otherwise the canvas shows an agent-less swarm until the next feed poll.
    # Re-enter through the one snapshot handler instead of duplicating it;
    # maybe_push_layout suppresses the redundant init.
    if connected?(socket) && snap, do: send(self(), {:snapshot, snap})

    {:ok,
     socket
     |> assign(page_title: "Topology", debug: false, pipeline_layout: layout)
     |> push_event("pipeline:init", layout)}
  end

  # ?debug=1 shows the hook's trace rig. The hook el is phx-update="ignore", so
  # data-debug is read once AT MOUNT — the param arrives with the page load.
  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, debug: params["debug"] == "1")}

  # Package-group chips under the canvas: toggling re-lays the canvas with
  # that group expanded/collapsed, then replays the snapshot so the agent
  # grid re-seeds immediately instead of waiting for the next feed poll.
  @impl true
  def handle_event("topo_group", %{"name" => name}, socket) when is_binary(name) do
    expanded = socket.assigns[:topo_expanded] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, name),
        do: MapSet.delete(expanded, name),
        else: MapSet.put(expanded, name)

    socket = assign(socket, :topo_expanded, expanded)
    if socket.assigns[:snapshot], do: send(self(), {:snapshot, socket.assigns[:snapshot]})
    {:noreply, socket}
  end

  @impl true
  # Raw display events drive the canvas; the hook owns playback timing (causal).
  def handle_info({:display_event, ev}, socket),
    do:
      {:noreply,
       push_event(
         socket,
         "pipeline:event",
         display_event_for_privacy(ev, socket.assigns[:privacy] == true)
       )}

  # Agent nodes are dynamic. Precedence (spec §5.5): the snapshot wins existence
  # (which slots are in the pool), the event story wins activity state.
  # `handles` carries a per-slot overlay for a leased slot: the session id it
  # serves (the canvas labels the node "agent_15" + that session id) and an
  # avatar seed (the telegram handle) — the identity lives in the drawn avatar,
  # not in a "@handle" text label.
  def handle_info({:snapshot, snap}, socket) do
    privacy? = socket.assigns[:privacy] == true
    inspect_lookup = DashHooks.inspect_lookup(snap)
    layout = pipeline_layout(snap, socket.assigns[:topo_expanded] || MapSet.new())

    socket =
      socket
      |> assign(:inspect_lookup, inspect_lookup)
      |> maybe_push_layout(layout)
      |> push_event("pipeline:agents", agents_payload(snap, privacy?, inspect_lookup))

    {:noreply, socket}
  end

  # The TRUE in-flight set (what the strip shows) → hook reconciliation: once
  # the causal animation drains, busy rings the truth doesn't back are lost
  # events and get released instead of waiting out the decay timeout.
  def handle_info({:story, summary}, socket) do
    busy =
      for ep <- summary[:in_flight] || [], is_binary(ep[:agent]), do: ep.agent

    {:noreply, push_event(socket, "pipeline:truth", %{busy: Enum.uniq(busy)})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    privacy? = assigns[:privacy] == true
    inspect_lookup = assigns[:inspect_lookup] || DashHooks.inspect_lookup(assigns[:snapshot])

    assigns =
      assigns
      |> assign(:inspect_lookup, inspect_lookup)
      |> assign(:layout_snapshot, DashHooks.layout_snapshot(assigns[:snapshot], privacy?))
      |> assign(:nodes, table_nodes(assigns[:snapshot], privacy?, inspect_lookup))
      |> assign(:gauge, pool_meta(assigns[:snapshot]))
      |> assign(:in_flight, (assigns[:story] && assigns.story[:in_flight]) || [])
      # set by config/runtime.exs when the host overlay was rejected whole
      |> assign(
        :overlay_error,
        Application.get_env(:subzero_swarm_dashboard, :topology_overlay_error)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:topology}
      swarm={@swarm}
      snapshot={@layout_snapshot}
      story={@story}
      privacy={@privacy}
      inspect={@inspect}
      inspect_transcript={@inspect_transcript}
      inspect_activity={@inspect_activity}
    >
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h1 class="text-2xl">Topology</h1>
          <div
            :if={@gauge.ok}
            class="flex items-center gap-1.5"
            title={"pool #{@gauge.leased} of #{@gauge.size} leased"}
          >
            <div
              class="radial-progress tnum text-[0.6rem]"
              style={"--value:#{@gauge.pct}; --size:2.4rem; --thickness:3px; color:#{@gauge.tone}"}
              role="progressbar"
              aria-label="pool saturation"
              aria-valuenow={@gauge.pct}
              aria-valuemin="0"
              aria-valuemax="100"
            >
              <span class="text-base-content">{@gauge.leased}/{@gauge.size}</span>
            </div>
            <span class="text-xs opacity-60">pool</span>
          </div>
        </div>

        <div
          :if={@overlay_error}
          id="topology-overlay-error"
          class="alert alert-warning text-xs py-2"
          role="status"
        >
          <span>
            host topology overlay rejected — {@overlay_error}. The canvas is drawn without
            package groups, descriptions, aliases or external endpoints until the
            <code>DASHBOARD_TOPOLOGY_OVERLAY*</code>
            value is fixed.
          </span>
        </div>

        <div
          id="pipeline"
          phx-hook="Pipeline"
          phx-update="ignore"
          data-debug={@debug && "1"}
          class="pipeline-terminal w-full h-[64vh] rounded-box border relative overflow-hidden"
        >
        </div>

        <div
          :if={(@pipeline_layout[:groups] || []) != []}
          id="pipeline-groups"
          class="flex flex-wrap items-center gap-2 text-xs"
        >
          <span class="opacity-50">packages:</span>
          <button
            :for={g <- @pipeline_layout[:groups]}
            type="button"
            phx-click="topo_group"
            phx-value-name={g.name}
            class="btn btn-xs gap-1"
            title={Enum.join(g.members, ", ")}
          >
            {if g.expanded, do: "▾", else: "▸"} {g.name}
            <span class="opacity-60 tnum">{g.count}</span>
          </button>
        </div>

        <div
          id="pipeline-legend"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs opacity-70"
        >
          <span><span class="text-primary">●</span> thinking</span>
          <span>
            <span class="text-warning">◐</span> waiting · dashed edge → the service it waits on
          </span>
          <span><span class="text-info">◌</span> spawning</span>
          <span><span class="text-warning font-mono">⁺¹</span> queued turns</span>
          <span><span class="text-success">⤸</span> reply arc</span>
          <span><span class="text-error">◉</span> failure flash</span>
          <span>☕ compacting · 🤫 suppressed · ⛔ budget wall · ✓ cron ok</span>
        </div>

        <section id="pipeline-inflight" class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="text-xs uppercase tracking-wider opacity-60 mb-2">In flight · user requests</h2>
          <%= cond do %>
            <% @story == nil or @story[:feed_status] != :ok -> %>
              <p class="text-sm opacity-60">
                event feed unavailable — the canvas stays quiet; the node table below still reflects the snapshot.
              </p>
            <% @in_flight == [] -> %>
              <p class="text-sm opacity-60">nobody waiting</p>
            <% true -> %>
              <div class="space-y-1 font-mono text-sm">
                <div :for={ep <- @in_flight} class="flex items-baseline gap-3">
                  <span class="min-w-32 truncate">
                    @{display_handle(@snapshot, ep, @privacy)}
                  </span>
                  <span class="opacity-80">{short(ep.agent) || "routing…"}</span>
                  <span class={activity_tone(ep.activity)}>
                    {ep.activity}<span
                      :if={queued_turns(@story, ep) > 0}
                      class="opacity-60"
                      title="messages from this user waiting for the current turn to finish"
                    > · +{queued_turns(@story, ep)} queued</span>
                  </span>
                  <span :if={ep.stalled} class="badge badge-error badge-xs">stalled</span>
                  <span class="tnum ml-auto opacity-60">{duration(ep.elapsed_s)}</span>
                  <% inspect_target = inspect_value(@inspect_lookup, @privacy, ep.cid) %>
                  <%= if @privacy do %>
                    <button
                      :if={inspect_target}
                      type="button"
                      phx-click="inspect"
                      phx-value-session_id={inspect_target}
                      class="link link-hover text-xs opacity-70 whitespace-nowrap"
                    >
                      session
                    </button>
                  <% else %>
                    <.link
                      navigate={session_href(ep.cid)}
                      class="link link-hover text-xs opacity-70 whitespace-nowrap"
                    >
                      session
                    </.link>
                  <% end %>
                </div>
              </div>
          <% end %>
          <p class="text-[0.7rem] opacity-40 mt-2">
            true state, updated instantly — the canvas above replays the same events at causal pace
          </p>
        </section>

        <details :if={@snapshot} class="text-sm">
          <summary class="cursor-pointer opacity-70">Nodes (table fallback)</summary>
          <table class="table table-sm mt-2">
            <thead>
              <tr>
                <th>user / name</th>
                <th>type</th>
                <th>state</th>
                <th>session</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={n <- @nodes}
                class={[n["type"] == "agent" && n["inspect_value"] && "row-press"]}
                phx-click={n["type"] == "agent" && n["inspect_value"] && "inspect"}
                phx-keydown={n["type"] == "agent" && n["inspect_value"] && "inspect"}
                phx-key="Enter"
                phx-value-session_id={n["inspect_value"]}
                tabindex={if(n["type"] == "agent" && n["inspect_value"], do: "0")}
              >
                <td>
                  <%= if n["type"] == "agent" and @privacy do %>
                    <div class="flex items-center gap-2.5 min-w-0">
                      <.identity_avatar
                        user={n["raw_user"]}
                        session_id={n["raw_session_id"]}
                        label={n["raw_label"]}
                        privacy={@privacy}
                        size={:sm}
                      />
                      <span class="font-mono text-sm">•••</span>
                    </div>
                  <% else %>
                    <.identity
                      :if={n["type"] == "agent"}
                      user={n["user"]}
                      session_id={n["session_id"]}
                      label={n["label"]}
                      size={:sm}
                    />
                  <% end %>
                  <span :if={n["type"] != "agent"} class="font-mono">{n["name"]}</span>
                </td>
                <td>{n["type"]}</td>
                <td>
                  <.live_dot :if={n["type"] == "agent"} state={n["state"]} />
                  <span
                    :if={n["type"] != "agent"}
                    class="opacity-50"
                  >
                    {n["subtype"]}
                  </span>
                </td>
                <td class="font-mono text-xs opacity-60">{n["session_id"]}</td>
              </tr>
            </tbody>
          </table>
        </details>

        <div :if={is_nil(@snapshot)} class="opacity-60">Waiting for the first snapshot…</div>
      </div>
    </Layouts.app>
    """
  end

  # Pool saturation for the header gauge: leased/size with a green→amber→red tone.
  defp pool_meta(snap) do
    case get_in(snap, ["summary", "pool"]) do
      %{"leased" => l, "size" => s} when is_integer(s) and s > 0 ->
        pct = round(l / s * 100)
        %{ok: true, leased: l, size: s, pct: pct, tone: pool_tone(pct)}

      %{"leased" => l, "size" => s} ->
        %{ok: true, leased: l, size: s, pct: 0, tone: pool_tone(0)}

      _ ->
        %{ok: false, leased: 0, size: 0, pct: 0, tone: pool_tone(0)}
    end
  end

  defp pool_tone(pct) when pct >= 90, do: "var(--color-error)"
  defp pool_tone(pct) when pct >= 70, do: "var(--color-warning)"
  defp pool_tone(_pct), do: "var(--color-success)"

  defp agents_payload(snap, privacy?, inspect_lookup) do
    %{
      agents: agent_names(snap),
      handles: agent_handles(snap, privacy?),
      sessions: agent_session_targets(snap, privacy?, inspect_lookup)
    }
    |> maybe_add_display_names(snap, privacy?)
    |> maybe_add_session_labels(snap, privacy?)
  end

  # slot => the human the slot serves, as its canvas label: @handle first, then
  # the user's display name, then the session label. Privacy mode omits the map
  # entirely — the canvas falls back to identity-free slot ids.
  defp maybe_add_display_names(payload, _snap, true), do: payload

  defp maybe_add_display_names(payload, snap, false),
    do: Map.put(payload, :names, agent_display_names(snap))

  @doc """
  slot => display name for the canvas label. Same active-wins precedence as
  `agent_handles/1`. Public for unit tests.
  """
  def agent_display_names(snap) do
    (snap["sessions"] || [])
    |> Enum.filter(&is_binary(&1["agent"]))
    # actives sort LAST so they win the Map.new overwrite
    |> Enum.sort_by(&(&1["state"] == "active"))
    |> Enum.reduce(%{}, fn s, acc ->
      case display_name(s) do
        nil -> acc
        name -> Map.put(acc, s["agent"], name)
      end
    end)
  end

  defp display_name(s) do
    handle = get_in(s, ["user", "handle"])
    name = get_in(s, ["user", "name"])
    label = s["label"]

    cond do
      is_binary(handle) and handle != "" -> "@" <> handle
      is_binary(name) and name != "" -> name
      is_binary(label) and label != "" -> label
      true -> nil
    end
  end

  defp maybe_push_layout(socket, layout) do
    if socket.assigns[:pipeline_layout] == layout do
      socket
    else
      socket
      |> assign(:pipeline_layout, layout)
      |> push_event("pipeline:init", layout)
    end
  end

  # Sample/template swarm members (conversation_sample) are scaffolding, not
  # user-request pipeline — the pre-0.4.0 lane map filtered them via
  # agent_pattern config; name-based is the generic equivalent.
  @sample_agent ~r/sample|template/

  # Through normalize_nodes/1 so atom-keyed snapshots reach the grid too —
  # this is the ONLY route an agent takes to the canvas.
  defp agent_names(snap) do
    snap
    |> normalize_nodes()
    |> Enum.flat_map(fn
      %{type: "agent", name: name} -> [name]
      _ -> []
    end)
    |> Enum.reject(&Regex.match?(@sample_agent, &1))
  end

  @doc """
  Builds the canvas topology directly from a swarm dashboard snapshot.

  Agent slots are never fixed nodes — the hook lays them out in its centered
  wrapping grid (`pipeline:agents`), which stays readable from 1 to 60 slots.
  When a swarm has agents, the remaining objects band by role: objects that
  exchange messages with agents (the services the request flows through) sit
  above the grid, bookkeeping objects below — swarm message graphs are
  naturally cyclic (request/reply), so layering by edge direction degenerates.
  Oversized bands wrap into extra rows; `agent_y_min`/`agent_y_max` hand the
  hook the vertical corridor left between the innermost occupied rows, so the
  grid moves toward the emptier side instead of colliding with a band. Durable
  rails only connect fixed nodes; agent legs animate as live traffic.
  Agent-less snapshots keep the layered DAG arrangement, falling back to a
  compact grid when edgeless or cyclic.
  """
  def pipeline_layout(snapshot, expanded \\ MapSet.new()) do
    nodes = normalize_nodes(snapshot)
    edges = normalize_edges(snapshot, nodes)
    {nodes, edges} = collapse_shards(nodes, edges)

    groups_cfg = Application.get_env(:subzero_swarm_dashboard, :node_groups, %{})

    {nodes, edges, group_meta, group_aliases} =
      collapse_groups(nodes, edges, groups_cfg, expanded)

    # Positioning pass: EVERY group occupies one band slot — expanded groups
    # fold to an anchor here too, then their members fan out in a local grid
    # around that anchor inside a dotted box (the box is the collapse handle).
    expanded_meta = Enum.filter(group_meta, & &1.expanded)

    anchor_rename =
      for g <- expanded_meta, m <- g.members, into: %{}, do: {m, g.name}

    {pos_nodes, pos_edges} = fold_nodes(nodes, edges, anchor_rename)

    {agents, pos_objects} = Enum.split_with(pos_nodes, &(&1.type == "agent"))

    {positions, {agent_y_min, agent_y_max}} =
      if agents == [] do
        {node_positions(pos_objects, pos_edges), {@agent_y_min_default, @agent_y_max_default}}
      else
        banded_positions(pos_objects, pos_edges, MapSet.new(agents, & &1.name))
      end

    # Display labels first: box extents and collision math need approximate
    # chip widths, which depend on the label actually drawn.
    member_labels =
      for g <- expanded_meta, m <- g.members, into: %{} do
        {m, String.replace_prefix(m, g.name <> "_", "")}
      end

    {positions, boxes, {agent_y_min, agent_y_max}} =
      place_expanded_members(positions, expanded_meta, {agent_y_min, agent_y_max}, member_labels)

    expanded_members = MapSet.new(for g <- expanded_meta, m <- g.members, do: m)
    positions = push_aside(positions, boxes, expanded_members, member_labels)

    # Object hover cards: host-provided descriptions per node name; the
    # :agent key covers every dynamic agent chip. Config data, text-only —
    # the hook renders it with textContent, never markup.
    descs = Application.get_env(:subzero_swarm_dashboard, :object_descriptions, %{})

    # Event vocabulary → this swarm's real object names ("ingress" →
    # "tg_ingress"); host-provided so packets land on snapshot nodes instead
    # of being dropped for lack of a position.
    # Aliases flatten through collapsed groups so a canonical name lands on
    # whatever node currently exists ("bet" -> market_bet -> market).
    aliases =
      Application.get_env(:subzero_swarm_dashboard, :node_aliases, %{})
      |> Map.new(fn {k, v} -> {k, Map.get(group_aliases, v, v)} end)
      |> Map.merge(group_aliases)

    collapsed_names = group_meta |> Enum.reject(& &1.expanded) |> MapSet.new(& &1.name)

    group_descs =
      Map.new(group_meta, fn g ->
        {g.name, "Package group · #{g.count} objects: #{Enum.join(g.members, ", ")}"}
      end)

    objects = Enum.reject(nodes, &(&1.type == "agent"))

    # External endpoints the display vocabulary talks to but no swarm object
    # backs ("telegram" — the Telegram API, "web") get small ext circles
    # stacked on the right edge, so reply/browse packets visibly LEAVE the
    # swarm instead of being dropped.
    ext_names = Application.get_env(:subzero_swarm_dashboard, :ext_endpoints, [])

    ext_nodes =
      ext_names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} ->
        y = 0.5 + (i - (length(ext_names) - 1) / 2) * 0.16

        %{
          name: name,
          x: 0.955,
          y: y,
          kind: "ext",
          r: 15,
          desc: Map.get(descs, name),
          group: false
        }
      end)

    %{
      aliases: aliases,
      agent_desc: Map.get(descs, :agent),
      groups: group_meta,
      boxes: boxes,
      nodes:
        for(
          node <- objects,
          Map.has_key?(positions, node.name),
          do: %{
            name: node.name,
            label: Map.get(member_labels, node.name, node.name),
            x: elem(Map.fetch!(positions, node.name), 0),
            y: elem(Map.fetch!(positions, node.name), 1),
            kind: canvas_kind(node.type),
            r: canvas_radius(node.type),
            desc: Map.get(group_descs, node.name) || Map.get(descs, node.name),
            group: MapSet.member?(collapsed_names, node.name)
          }
        ) ++ ext_nodes,
      edges:
        for {from, to} <- edges,
            Map.has_key?(positions, from) and Map.has_key?(positions, to) do
          %{from: from, to: to}
        end,
      chatter: [],
      return_arcs: [],
      agent_y_min: agent_y_min,
      agent_y_max: agent_y_max
    }
  end

  # Fan an expanded group's members out in a centered grid at the group's band
  # anchor, growing toward the canvas center, and emit the dotted-box rect
  # (canvas fractions) that visually contains them. The anchor position is
  # consumed — the box itself is the collapse control. The agent corridor is
  # squeezed past each box so the grid never sits under member chips.
  @box_dx 0.1
  @box_dy 0.088
  @box_pad_x 0.045
  @box_pad_top 0.052
  @box_pad_bottom 0.03
  # Band neighbours that would sit under an open box slide out of its way:
  # non-member nodes whose slot falls inside a box rect fan outward past the
  # nearer box edge, preserving their left/right order. Without this, the
  # member grid overlaps whatever else shares the band row.
  # Approximate half-width of a drawn chip (fraction of canvas width):
  # 12px mono ~7.2px/char plus padding, conservative for narrow viewports.
  defp approx_hw(label), do: 0.0026 * String.length(label) + 0.016

  defp push_aside(positions, [], _members, _labels), do: positions

  # Band neighbours whose CHIP EXTENT (not just center) intersects an open
  # box slide out past the nearer box edge, stacked outward with their own
  # widths so pushed chips cannot overlap each other either.
  defp push_aside(positions, boxes, members, labels) do
    Enum.reduce(boxes, positions, fn box, pos ->
      {inside, outside} =
        Enum.split_with(pos, fn {name, {x, y}} ->
          hw = approx_hw(Map.get(labels, name, name))

          not MapSet.member?(members, name) and
            y >= box.y0 - 0.02 and y <= box.y1 + 0.02 and
            x + hw >= box.x0 and x - hw <= box.x1
        end)

      moved =
        inside
        |> Enum.group_by(fn {_n, {x, y}} ->
          {Float.round(y * 1.0, 3), x <= (box.x0 + box.x1) / 2}
        end)
        |> Enum.flat_map(fn {{y, left?}, entries} ->
          entries
          |> Enum.sort_by(fn {_n, {x, _y}} -> if left?, do: -x, else: x end)
          |> Enum.map_reduce(
            if(left?, do: box.x0 - 0.02, else: box.x1 + 0.02),
            fn {name, _xy}, cursor ->
              hw = approx_hw(Map.get(labels, name, name))
              x = if left?, do: cursor - hw, else: cursor + hw
              next = if left?, do: x - hw - 0.025, else: x + hw + 0.025
              {{name, {x |> max(0.03) |> min(0.97), y}}, next}
            end
          )
          |> elem(0)
        end)

      Map.merge(Map.new(outside), Map.new(moved))
    end)
  end

  defp place_expanded_members(positions, [], corridor, _labels), do: {positions, [], corridor}

  # Open boxes TILE: each band's expanded groups split the width into
  # disjoint lanes (no two open boxes can collide), with grid columns
  # adapted to the lane width. Grids grow from the band edge toward center.
  defp place_expanded_members(positions, expanded_meta, corridor, labels) do
    {top, bottom} =
      Enum.split_with(expanded_meta, fn g ->
        case Map.fetch(positions, g.name) do
          {:ok, {_x, y}} -> y < 0.5
          :error -> true
        end
      end)

    {positions, top_boxes, corridor} = place_band(positions, top, true, corridor, labels)
    {positions, bottom_boxes, corridor} = place_band(positions, bottom, false, corridor, labels)
    {positions, top_boxes ++ bottom_boxes, corridor}
  end

  defp place_band(positions, [], _top?, corridor, _labels), do: {positions, [], corridor}

  defp place_band(positions, metas, top?, corridor, labels) do
    lane_w = 0.92 / length(metas)

    metas
    |> Enum.with_index()
    |> Enum.reduce({positions, [], corridor}, fn {g, i}, {pos, boxes, {ymin, ymax}} ->
      cx = 0.04 + lane_w * (i + 0.5)

      cols =
        ((lane_w - 2 * @box_pad_x) / @box_dx)
        |> Float.floor()
        |> trunc()
        |> Kernel.+(1)
        |> max(2)
        |> min(4)

      n = length(g.members)
      rows = div(n + cols - 1, cols)
      base_y = if top?, do: @band_top_y, else: @band_bottom_y
      row_y = fn r -> if top?, do: base_y + r * @box_dy, else: base_y - r * @box_dy end

      placed =
        g.members
        |> Enum.with_index()
        |> Enum.map(fn {m, j} ->
          r = div(j, cols)
          c = rem(j, cols)
          in_row = min(cols, n - r * cols)
          x = cx + (c - (in_row - 1) / 2) * @box_dx
          {m, x, row_y.(r)}
        end)

      pos = Enum.reduce(placed, pos, fn {m, x, y}, p -> Map.put(p, m, {x, y}) end)
      pos = Map.delete(pos, g.name)

      ys = Enum.map(0..(rows - 1), &row_y.(&1))
      y_lo = Enum.min(ys)
      y_hi = Enum.max(ys)

      # Real horizontal extent: outermost chip EDGE (approx width), not the
      # grid centers — push_aside and the corridor both key off this.
      x_lo =
        placed
        |> Enum.map(fn {m, x, _y} -> x - approx_hw(Map.get(labels, m, m)) end)
        |> Enum.min()

      x_hi =
        placed
        |> Enum.map(fn {m, x, _y} -> x + approx_hw(Map.get(labels, m, m)) end)
        |> Enum.max()

      box = %{
        name: g.name,
        members: g.members,
        x0: x_lo - 0.012,
        x1: x_hi + 0.012,
        y0: y_lo - if(top?, do: @box_pad_top, else: @box_pad_bottom) - 0.018,
        y1: y_hi + if(top?, do: @box_pad_bottom, else: @box_pad_top) + 0.018
      }

      corridor =
        if top?,
          do: {max(ymin, box.y1 + 0.05), ymax},
          else: {ymin, min(ymax, box.y0 - 0.05)}

      {pos, [box | boxes], corridor}
    end)
    |> then(fn {pos, boxes, corridor} -> {pos, Enum.reverse(boxes), corridor} end)
  end

  # Generic node folding: members rename onto their target node (created if
  # absent), edges follow, self-loops drop.
  defp fold_nodes(nodes, edges, rename) when map_size(rename) == 0, do: {nodes, edges}

  defp fold_nodes(nodes, edges, rename) do
    existing = MapSet.new(nodes, & &1.name)

    target_nodes =
      rename
      |> Map.values()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.map(&%{name: &1, type: "object"})

    kept = Enum.reject(nodes, &Map.has_key?(rename, &1.name)) ++ target_nodes

    folded =
      edges
      |> Enum.map(fn {from, to} -> {Map.get(rename, from, from), Map.get(rename, to, to)} end)
      |> Enum.reject(fn {from, to} -> from == to end)
      |> Enum.uniq()
      |> Enum.sort()

    {Enum.sort_by(kept, & &1.name), folded}
  end

  # Host-configured package groups (`:node_groups`): each collapsed group
  # replaces its member objects with ONE super-node named after the group,
  # folding member edges onto it — the canvas stays readable however many
  # objects a swarm wires. Expanded groups keep their members as plain nodes.
  # Returns {nodes, edges, group_meta, member->group rename map}.
  defp collapse_groups(nodes, edges, groups_cfg, expanded) when map_size(groups_cfg) > 0 do
    names = MapSet.new(nodes, & &1.name)

    {meta, rename} =
      Enum.reduce(groups_cfg, {[], %{}}, fn {group, members}, {meta, rename} ->
        present = members |> List.wrap() |> Enum.filter(&MapSet.member?(names, &1)) |> Enum.sort()

        cond do
          present == [] ->
            {meta, rename}

          MapSet.member?(expanded, group) ->
            {[%{name: group, count: length(present), expanded: true, members: present} | meta],
             rename}

          true ->
            {[%{name: group, count: length(present), expanded: false, members: present} | meta],
             Enum.into(present, rename, &{&1, group})}
        end
      end)

    meta = Enum.sort_by(meta, & &1.name)

    if rename == %{} do
      {nodes, edges, meta, %{}}
    else
      group_nodes =
        rename |> Map.values() |> Enum.uniq() |> Enum.map(&%{name: &1, type: "object"})

      kept = Enum.reject(nodes, &Map.has_key?(rename, &1.name)) ++ group_nodes

      folded =
        edges
        |> Enum.map(fn {from, to} -> {Map.get(rename, from, from), Map.get(rename, to, to)} end)
        |> Enum.reject(fn {from, to} -> from == to end)
        |> Enum.uniq()
        |> Enum.sort()

      {Enum.sort_by(kept, & &1.name), folded, meta, rename}
    end
  end

  defp collapse_groups(nodes, edges, _groups_cfg, _expanded), do: {nodes, edges, [], %{}}

  # Fixed shard workers (`<router>_shard_N`) are an implementation detail of
  # their router object; drawing 16 of them per router drowns the canvas.
  # Collapse each shard into its router when the router itself is in the
  # snapshot, folding shard edges onto the router (self-loops dropped).
  @shard_suffix ~r/^(.+)_shard_\d+$/
  defp collapse_shards(nodes, edges) do
    names = MapSet.new(nodes, & &1.name)

    rename =
      for %{name: name} <- nodes,
          [_, parent] <- [Regex.run(@shard_suffix, name)],
          MapSet.member?(names, parent),
          into: %{} do
        {name, parent}
      end

    if rename == %{} do
      {nodes, edges}
    else
      kept = Enum.reject(nodes, &Map.has_key?(rename, &1.name))

      folded =
        edges
        |> Enum.map(fn {from, to} -> {Map.get(rename, from, from), Map.get(rename, to, to)} end)
        |> Enum.reject(fn {from, to} -> from == to end)
        |> Enum.uniq()
        |> Enum.sort()

      {kept, folded}
    end
  end

  defp normalize_nodes(%{"nodes" => raw_nodes}) when is_list(raw_nodes) do
    raw_nodes
    |> Enum.reduce(%{}, fn
      node, acc when is_map(node) ->
        name = field(node, "name", :name)
        type = field(node, "type", :type)

        if is_binary(name) and name != "" do
          Map.put_new(acc, name, %{name: name, type: type})
        else
          acc
        end

      _, acc ->
        acc
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_nodes(%{nodes: raw_nodes}) when is_list(raw_nodes),
    do: normalize_nodes(%{"nodes" => raw_nodes})

  defp normalize_nodes(_snapshot), do: []

  defp normalize_edges(snapshot, nodes) do
    names = nodes |> Enum.map(& &1.name) |> MapSet.new()

    snapshot
    |> raw_edges()
    |> Enum.reduce(MapSet.new(), fn
      edge, acc when is_map(edge) ->
        from = field(edge, "from", :from)
        to = field(edge, "to", :to)

        if is_binary(from) and is_binary(to) and from != to and
             MapSet.member?(names, from) and MapSet.member?(names, to) do
          MapSet.put(acc, {from, to})
        else
          acc
        end

      _, acc ->
        acc
    end)
    |> Enum.sort()
  end

  defp raw_edges(%{"edges" => edges}) when is_list(edges), do: edges
  defp raw_edges(%{edges: edges}) when is_list(edges), do: edges
  defp raw_edges(_snapshot), do: []

  defp field(map, string_key, atom_key), do: Map.get(map, string_key, Map.get(map, atom_key))

  # No "agent" clauses: agents never become fixed nodes — the hook owns their
  # look (grid dot radius lives in pipeline.js).
  defp canvas_kind(type) when type in ["external", "endpoint", "transport"], do: "ext"
  defp canvas_kind(_type), do: "obj"

  defp canvas_radius(type) when type in ["external", "endpoint", "transport"], do: 15
  defp canvas_radius(_type), do: 18

  # Split objects into the service band (anything that exchanges messages with
  # an agent) and the bookkeeping band, then stack each band's rows outward
  # from its canvas edge. Returns {positions, {agent_y_min, agent_y_max}}: the
  # corridor between each band's innermost occupied row (plus clearance),
  # which is where the hook may draw the agent grid.
  defp banded_positions(objects, edges, agent_names) do
    services =
      Enum.reduce(edges, MapSet.new(), fn {from, to}, acc ->
        acc = if MapSet.member?(agent_names, to), do: MapSet.put(acc, from), else: acc
        if MapSet.member?(agent_names, from), do: MapSet.put(acc, to), else: acc
      end)

    {top, bottom} = Enum.split_with(objects, &MapSet.member?(services, &1.name))
    {top, bottom} = barycentric_sweep(top, bottom, object_neighbors(edges, agent_names))
    top_rows = band_rows(top)
    bottom_rows = band_rows(bottom)

    positions =
      Map.merge(
        band_positions(top_rows, fn row -> @band_top_y + row * @band_row_step end),
        band_positions(bottom_rows, fn row -> @band_bottom_y - row * @band_row_step end)
      )

    y_min =
      case top_rows do
        [] -> @agent_y_min_default
        rows -> @band_top_y + (length(rows) - 1) * @band_row_step + @band_clearance
      end

    y_max =
      case bottom_rows do
        [] -> @agent_y_max_default
        rows -> @band_bottom_y - (length(rows) - 1) * @band_row_step - @band_clearance
      end

    {positions, clamp_corridor(y_min, y_max)}
  end

  # Pathologically deep bands can cross; collapse the corridor to a thin strip
  # at their midpoint so the grid stays drawable instead of inverting.
  defp clamp_corridor(y_min, y_max) when y_max - y_min >= 0.05, do: {y_min, y_max}

  defp clamp_corridor(y_min, y_max) do
    mid = (y_min + y_max) / 2
    {mid - 0.025, mid + 0.025}
  end

  # Undirected object<->object adjacency (agent legs excluded) — the input to
  # the ordering sweep below.
  defp object_neighbors(edges, agent_names) do
    edges
    |> Enum.reject(fn {from, to} ->
      MapSet.member?(agent_names, from) or MapSet.member?(agent_names, to)
    end)
    |> Enum.reduce(%{}, fn {from, to}, acc ->
      acc
      |> Map.update(from, [to], &[to | &1])
      |> Map.update(to, [from], &[from | &1])
    end)
  end

  # Crossing reduction: order each band by the barycenter of its neighbours'
  # current x instead of the alphabet, so rails run roughly vertically between
  # the bands rather than criss-crossing the whole canvas. A few alternating
  # sweeps of the classic layered heuristic; nodes without object neighbours
  # hold their current slot.
  defp barycentric_sweep(top, bottom, neighbors) do
    top = Enum.sort_by(top, & &1.name)
    bottom = Enum.sort_by(bottom, & &1.name)

    Enum.reduce(1..3, {top, bottom}, fn _, {t, b} ->
      xs = Map.merge(band_xs(t), band_xs(b))
      b = reorder_by_barycenter(b, xs, neighbors)
      xs = Map.merge(band_xs(t), band_xs(b))
      {reorder_by_barycenter(t, xs, neighbors), b}
    end)
  end

  defp band_xs(nodes) do
    count = length(nodes)

    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, index} -> {node.name, spread(index, count, 0.08, 0.92)} end)
  end

  defp reorder_by_barycenter(nodes, xs, neighbors) do
    Enum.sort_by(nodes, fn node ->
      own_x = Map.fetch!(xs, node.name)

      barycenter =
        case Map.get(neighbors, node.name, []) do
          [] ->
            own_x

          names ->
            case names |> Enum.map(&Map.get(xs, &1)) |> Enum.reject(&is_nil/1) do
              [] -> own_x
              neighbor_xs -> Enum.sum(neighbor_xs) / length(neighbor_xs)
            end
        end

      {barycenter, node.name}
    end)
  end

  # Balanced rows: 9 nodes over a 7-per-row cap become 5+4, not 7+2. Nodes are
  # dealt round-robin so the sweep's left-to-right order survives in EVERY row
  # (a straight chunk would put the left half in one row and the right half in
  # the other, undoing the crossing reduction).
  defp band_rows([]), do: []

  defp band_rows(nodes) do
    rows = ceil_div(length(nodes), @band_row_max)

    nodes
    |> Enum.with_index()
    |> Enum.group_by(fn {_node, index} -> rem(index, rows) end)
    |> Enum.sort_by(fn {row, _pairs} -> row end)
    |> Enum.map(fn {_row, pairs} -> Enum.map(pairs, &elem(&1, 0)) end)
  end

  defp band_positions(rows, row_y) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row_nodes, row} ->
      row_nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, column} ->
        {node.name, {row_x(column, length(row_nodes)), row_y.(row)}}
      end)
    end)
    |> Map.new()
  end

  # Rows center with CAPPED spacing instead of spanning the full canvas —
  # a small row should read as a cluster, not as corner flags at the edges.
  @band_col_step 0.17
  defp row_x(_index, 1), do: 0.5

  defp row_x(index, count) do
    span = min(0.84, (count - 1) * @band_col_step)
    0.5 - span / 2 + index * span / (count - 1)
  end

  defp node_positions([], _edges), do: %{}
  defp node_positions(nodes, []), do: grid_positions(nodes)

  defp node_positions(nodes, edges) do
    names = Enum.map(nodes, & &1.name)

    case graph_depths(names, edges) do
      {:ok, depths} -> layered_positions(nodes, depths)
      :cyclic -> grid_positions(nodes)
    end
  end

  defp layered_positions(nodes, depths) do
    levels = depths |> Map.values() |> Enum.uniq() |> Enum.sort()
    level_indexes = levels |> Enum.with_index() |> Map.new()

    nodes
    |> Enum.group_by(&Map.fetch!(depths, &1.name))
    |> Enum.flat_map(fn {depth, level_nodes} ->
      level_index = Map.fetch!(level_indexes, depth)
      x = spread(level_index, length(levels), 0.14, 0.86)
      ordered = Enum.sort_by(level_nodes, & &1.name)

      ordered
      |> Enum.with_index()
      |> Enum.map(fn {node, row} ->
        {node.name, {x, spread(row, length(ordered), 0.16, 0.84)}}
      end)
    end)
    |> Map.new()
  end

  defp grid_positions(nodes) do
    count = length(nodes)
    columns = count |> Kernel.*(2) |> :math.sqrt() |> Float.ceil() |> trunc() |> max(1)
    rows = ceil_div(count, columns)

    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, index} ->
      column = rem(index, columns)
      row = div(index, columns)

      {node.name, {spread(column, columns, 0.14, 0.86), spread(row, rows, 0.2, 0.8)}}
    end)
  end

  defp graph_depths(names, edges) do
    indegrees = Map.new(names, &{&1, 0})
    outgoing = Map.new(names, &{&1, []})

    {indegrees, outgoing} =
      Enum.reduce(edges, {indegrees, outgoing}, fn {from, to}, {ins, outs} ->
        {Map.update!(ins, to, &(&1 + 1)), Map.update!(outs, from, &[to | &1])}
      end)

    queue = names |> Enum.filter(&(Map.fetch!(indegrees, &1) == 0)) |> Enum.sort()
    depths = Map.new(names, &{&1, 0})
    {depths, visited} = walk_layers(queue, indegrees, outgoing, depths, MapSet.new())

    if MapSet.size(visited) == length(names), do: {:ok, depths}, else: :cyclic
  end

  defp walk_layers([], _indegrees, _outgoing, depths, visited), do: {depths, visited}

  defp walk_layers([name | rest], indegrees, outgoing, depths, visited) do
    {indegrees, depths, ready} =
      outgoing
      |> Map.fetch!(name)
      |> Enum.sort()
      |> Enum.reduce({indegrees, depths, []}, fn target, {ins, ds, became_ready} ->
        remaining = Map.fetch!(ins, target) - 1
        ins = Map.put(ins, target, remaining)
        ds = Map.update!(ds, target, &max(&1, Map.fetch!(ds, name) + 1))
        became_ready = if remaining == 0, do: [target | became_ready], else: became_ready
        {ins, ds, became_ready}
      end)

    queue = (rest ++ ready) |> Enum.uniq() |> Enum.sort()
    walk_layers(queue, indegrees, outgoing, depths, MapSet.put(visited, name))
  end

  defp spread(_index, 1, low, high), do: (low + high) / 2
  defp spread(index, count, low, high), do: low + index / (count - 1) * (high - low)
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  @doc """
  agent slot => avatar seed for the canvas. The seed is the telegram handle,
  falling back to adapter label / name / session id, so every leased slot gets a
  stable generated avatar even without a handle — the identity lives in the drawn
  avatar, not a "@handle" text label. Active sessions win over idle leftovers, so
  a recycled slot never wears the previous conversation's avatar. The session id
  the slot serves (drawn under the slot id) comes from `agent_sessions/1`. Public
  for unit tests.
  """
  def agent_handles(snap, privacy? \\ false) do
    (snap["sessions"] || [])
    |> Enum.filter(&is_binary(&1["agent"]))
    # actives sort LAST so they win the Map.new overwrite
    |> Enum.sort_by(&(&1["state"] == "active"))
    |> Enum.reduce(%{}, fn s, acc ->
      case CoreComponents.avatar_seed(s) do
        nil -> acc
        seed -> Map.put(acc, s["agent"], CoreComponents.avatar_seed_for_display(seed, privacy?))
      end
    end)
  end

  @doc """
  agent slot => session id, for canvas click→inspect and the label sub-line.
  Same active-wins precedence as `agent_handles/1` but NO display filter: a
  session without handle/label/name must still be clickable and labelled.
  Public for unit tests.
  """
  def agent_sessions(snap) do
    (snap["sessions"] || [])
    |> Enum.filter(&(is_binary(&1["agent"]) and is_binary(&1["session_id"])))
    # actives sort LAST so they win the Map.new overwrite
    |> Enum.sort_by(&(&1["state"] == "active"))
    |> Map.new(&{&1["agent"], &1["session_id"]})
  end

  defp agent_session_targets(snap, privacy?, inspect_lookup) do
    snap
    |> agent_sessions()
    |> Map.new(fn {agent, sid} -> {agent, inspect_value(inspect_lookup, privacy?, sid)} end)
  end

  defp agent_session_labels(snap, privacy?) do
    snap
    |> agent_sessions()
    |> Map.new(fn {agent, sid} -> {agent, display_session_id(sid, privacy?)} end)
  end

  defp maybe_add_session_labels(payload, _snap, false), do: payload

  defp maybe_add_session_labels(payload, snap, true),
    do: Map.put(payload, :session_labels, agent_session_labels(snap, true))

  defp display_event_for_privacy(ev, false), do: ev

  defp display_event_for_privacy(%{} = ev, true) do
    Map.new(ev, fn {key, value} ->
      {key, redact_display_event_value(to_string(key), value)}
    end)
  end

  defp display_event_for_privacy(ev, _privacy?), do: ev

  defp redact_display_event_value("cid", value) when is_binary(value),
    do: "cid:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp redact_display_event_value(key, value)
       when key in ["session_id", "chat_id", "conversation_id"] and is_binary(value),
       do: display_session_id(value, true)

  defp redact_display_event_value(key, value)
       when key in ["handle", "username", "name", "label", "user"] and is_binary(value),
       do: "•••"

  defp redact_display_event_value(key, value)
       when key in ["text", "message", "content"] and is_binary(value),
       do: PrivacyRedactor.mask_text(value)

  defp redact_display_event_value(_key, value), do: value

  # ── in-flight strip (TRUE state from @story — not the paced animation) ────────
  defp display_handle(_snap, _ep, true), do: "•••"
  defp display_handle(snap, ep, _privacy?), do: handle_for(snap, ep.cid, ep.user)

  defp inspect_value(lookup, privacy?, sid),
    do: DashHooks.inspect_value(lookup, privacy? == true, sid)

  defp short(nil), do: nil
  defp short(name), do: String.replace(name, ~r/^.+_agent_/, "agent_")

  # thinking = primary everywhere (Overview strip, the legend dot above) —
  # green is reserved for success/replied
  defp activity_tone("waiting on " <> _), do: "text-warning"
  defp activity_tone("thinking"), do: "text-primary"
  defp activity_tone("spawning"), do: "text-info"
  defp activity_tone(_activity), do: "opacity-60"

  # ── table fallback rows (with the joined user identity) ──────────────────────
  defp table_nodes(nil, _privacy?, _inspect_lookup), do: []

  defp table_nodes(snap, privacy?, inspect_lookup) do
    by_cid = Map.new(snap["sessions"] || [], &{&1["session_id"], &1})

    Enum.map(snap["nodes"] || [], fn n ->
      sess = n["session_id"] && by_cid[n["session_id"]]
      raw_sid = n["session_id"]

      n
      |> Map.put("user", sess && sess["user"])
      |> Map.put("label", sess && sess["label"])
      |> Map.put("state", (sess && sess["state"]) || n["state"])
      |> Map.put("raw_user", sess && sess["user"])
      |> Map.put("raw_label", sess && sess["label"])
      |> Map.put("raw_session_id", raw_sid)
      |> Map.put("inspect_value", inspect_value(inspect_lookup, privacy?, raw_sid))
      |> maybe_mask_table_node(privacy?)
    end)
  end

  defp maybe_mask_table_node(n, false), do: n

  defp maybe_mask_table_node(n, true) do
    n
    |> Map.put("user", nil)
    |> Map.put("session_id", display_session_id(n["session_id"], true))
  end

  defp display_session_id(nil, _privacy?), do: nil
  defp display_session_id(sid, false), do: sid

  defp display_session_id(sid, true) when is_binary(sid) do
    case PrivacyRedactor.mask_cid(sid) do
      ^sid -> "•••"
      masked -> masked
    end
  end
end
