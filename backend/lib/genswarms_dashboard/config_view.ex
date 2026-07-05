defmodule GenswarmsDashboard.ConfigView do
  @moduledoc """
  Read-only view of a swarm's effective object configuration, redacted
  against each package's `config_schema` (gsp design §14.2.1).

  Fail-closed redaction rules, in order:

    * key in schema, not `x-secret`      → value shown (safe-rendered)
    * `x-secret` and key ends in `_env`  → value shown — by the x-secret
      contract the VALUE of an `*_env` field is the env var NAME, never the
      secret itself
    * `x-secret` otherwise               → value elided
    * key ABSENT from the schema         → value elided (an unlisted key is
      treated as sensitive)
    * object with NO schema              → every value elided, names only

  Schema discovery: the package's `swarm-object.json` sits next to the
  handler's source (same notarized dir the loader trusts) — resolved from
  `module_info(:compile)[:source]` and walked upward a bounded number of
  levels. The registry mirror is never consulted (behavior lives in the
  hashed bytes).

  The `build/2` half is pure (config in, view out) — unit-testable without
  an engine.
  """

  # deepest known layout: <pkg root>/lib/a/b/objects/handler.ex → 5 hops to root
  @max_walk_up 6
  @max_value_chars 400

  @doc """
  Build the wire view from a full swarm config map (`SwarmManager.get_full_config/1`
  shape: `%{objects: [%{name, handler, config}]}`) and a schema lookup
  function (`handler_module -> map | nil`).
  """
  def build(full_config, schema_fn) do
    objects =
      full_config
      |> Map.get(:objects, [])
      |> Enum.map(fn obj ->
        handler = Map.get(obj, :handler)
        schema = schema_fn.(handler)

        %{
          name: to_string(Map.get(obj, :name)),
          handler: handler_name(handler),
          has_schema: is_map(schema),
          config: redact(Map.get(obj, :config, %{}), schema)
        }
      end)

    %{objects: objects}
  end

  @doc "Redact one object's config map against its schema (nil ⇒ names only)."
  def redact(config, schema) when is_map(config) do
    props = if is_map(schema), do: Map.get(schema, "properties", %{}), else: %{}

    config
    |> Enum.map(fn {key, value} ->
      k = to_string(key)
      spec = Map.get(props, k)

      row = %{
        key: k,
        in_schema: is_map(spec),
        secret: is_map(spec) and Map.get(spec, "x-secret") == true,
        mutable: is_map(spec) and Map.get(spec, "x-mutable") == true,
        description: if(is_map(spec), do: Map.get(spec, "description"))
      }

      Map.put(row, :value, displayable_value(row, value))
    end)
    |> Enum.sort_by(& &1.key)
  end

  def redact(_config, _schema), do: []

  # ── redaction decision ───────────────────────────────────────────────────────

  defp displayable_value(%{in_schema: false}, _value), do: nil

  defp displayable_value(%{secret: true, key: key}, value) do
    # *_env fields carry the env var NAME (x-secret contract) — safe to show
    if String.ends_with?(key, "_env") and is_binary(value), do: value, else: nil
  end

  defp displayable_value(_row, value), do: safe_render(value)

  # ── JSON-safe rendering (configs carry atoms, modules, funs, tuples) ────────

  defp safe_render(v) when is_binary(v), do: String.slice(v, 0, @max_value_chars)
  defp safe_render(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp safe_render(v) when is_atom(v), do: inspect(v)

  defp safe_render(v) when is_list(v) do
    if length(v) <= 50, do: Enum.map(v, &safe_render/1), else: inspect_bounded(v)
  end

  defp safe_render(v) when is_map(v) do
    if map_size(v) <= 50 do
      Map.new(v, fn {k, val} -> {to_string_key(k), safe_render(val)} end)
    else
      inspect_bounded(v)
    end
  end

  # functions, pids, tuples, refs — opaque but identifiable
  defp safe_render(v), do: inspect_bounded(v)

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k), do: inspect(k)

  defp inspect_bounded(v),
    do: v |> inspect(limit: 20, printable_limit: @max_value_chars) |> String.slice(0, @max_value_chars)

  # ── schema discovery (impure half) ───────────────────────────────────────────

  @doc """
  Find the `config_schema` for a handler module: locate its compiled source
  file and walk up looking for `swarm-object.json` declaring this module.
  Returns the schema map or nil (⇒ names-only display, fail-closed).
  """
  def schema_for(handler) when is_atom(handler) and not is_nil(handler) do
    with true <- Code.ensure_loaded?(handler),
         source when is_list(source) <- handler.module_info(:compile)[:source] do
      source |> List.to_string() |> Path.dirname() |> find_schema(handler, @max_walk_up)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ref-map handlers (engine loader :require/:verify): the schema comes
  # straight from the swarm-object.json at the ref's path — the same
  # notarized bytes the loader digest-verified when it bound the module.
  def schema_for(%{} = ref_spec) do
    with path when is_binary(path) and path != "" <-
           Map.get(ref_spec, :path) || Map.get(ref_spec, "path"),
         {:ok, raw} <- File.read(Path.join(path, "swarm-object.json")),
         {:ok, %{"config_schema" => schema}} when is_map(schema) <- Jason.decode(raw) do
      schema
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def schema_for(_), do: nil

  defp find_schema(_dir, _handler, 0), do: nil

  defp find_schema(dir, handler, depth) do
    path = Path.join(dir, "swarm-object.json")

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"module" => mod, "config_schema" => schema}} when is_map(schema) ->
            # trust the schema only if the entry file binds THIS module
            if mod == handler_name(handler), do: schema, else: nil

          _ ->
            nil
        end

      _ ->
        parent = Path.dirname(dir)
        if parent == dir, do: nil, else: find_schema(parent, handler, depth - 1)
    end
  end

  defp handler_name(nil), do: nil
  defp handler_name(mod) when is_atom(mod), do: mod |> inspect()

  # ref-map handlers display as their notarized ref
  defp handler_name(%{} = spec),
    do: Map.get(spec, :ref) || Map.get(spec, "ref") || inspect(spec)

  defp handler_name(other), do: inspect(other)
end
