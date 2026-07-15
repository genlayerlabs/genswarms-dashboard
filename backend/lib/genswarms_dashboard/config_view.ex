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

  On top of the schema decision, EVERY shown value passes through a secret
  scrub (`deep_scrub/1`) before serialization: nested map/keyword keys that
  smell like credentials have their values replaced with `•••`, and
  credential-shaped substrings inside any binary are masked. The schema layer
  decides WHAT appears; the scrub guarantees a secret can't ride inside an
  allowed value — a schema can misdeclare a field (a `store` declared
  "string" that actually carries `{Module, %{bot_token: ...}}`), and the
  page must stay safe anyway.

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

  @redacted "•••"

  # Key names that smell like credentials, matched case-insensitively against
  # map keys and keyword-tuple keys at ANY nesting depth. `*_env` names are
  # exempt — by contract they carry the env var NAME, never the secret.
  @secret_key_re ~r/token|secret|passw|api_?key|credential|private_key|cookie/i

  # Credential-shaped substrings caught even under an innocent key: Telegram
  # bot tokens, sk- style API keys, GitHub/Slack token prefixes, bearer
  # headers, AWS access key ids, and URL userinfo (https://user:pass@host).
  # (no leading \b on the Telegram pattern: ".../bot<digits>:..." embeds the
  # token right after a word char, where \b never fires. URL userinfo allows an
  # empty user — `redis://:pass@host` is the standard passworded-Redis form.)
  @secret_value_re ~r"\d{8,11}:[A-Za-z0-9_-]{30,}\b|\bsk-[A-Za-z0-9_-]{16,}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{10,}\b|Bearer\s+\S{12,}|\bAKIA[0-9A-Z]{16}\b|(?<=://)[^/\s@]*:[^/\s@]+(?=@)"

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
    # *_env fields carry the env var NAME (x-secret contract) — safe to show,
    # but still scrub: a misconfigured *_env holding the literal token must not
    # render it.
    if String.ends_with?(key, "_env") and is_binary(value),
      do: deep_scrub(value),
      else: nil
  end

  # A single hostile value must never take the whole page down (an improper
  # list, an unencodable term) — fail closed to a mask, not a 500.
  defp displayable_value(_row, value) do
    safe_render(value)
  rescue
    _ -> @redacted
  end

  # ── secret scrub (runs on EVERY shown value, before serialization) ──────────

  # Scrubs the Elixir TERM, not the rendered string: the secret is gone before
  # inspect/1 can print it, and the binary regex pass is the second net rather
  # than the only one.
  defp deep_scrub(v) when is_binary(v), do: mask(v)

  defp deep_scrub(v) when is_struct(v), do: v |> Map.from_struct() |> deep_scrub()

  # Keys are scrubbed too: a map KEYED BY a secret (e.g. a per-token map) leaks
  # through the key, which scrub_entry/render never touch otherwise.
  defp deep_scrub(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {scrub_key(k), scrub_entry(k, val)} end)

  # A printable charlist is a credential carrier too — decode, scrub, keep as a
  # string only when it actually held a secret (else leave the list untouched
  # so ordinary integer lists render as lists).
  defp deep_scrub(v) when is_list(v) do
    if printable_charlist?(v) do
      s = List.to_string(v)
      if Regex.match?(@secret_value_re, s), do: mask(s), else: Enum.map(v, &deep_scrub/1)
    else
      Enum.map(v, &deep_scrub/1)
    end
  end

  # keyword-list entries follow the same key rule as map keys
  defp deep_scrub({k, val}) when is_atom(k), do: {k, scrub_entry(k, val)}

  defp deep_scrub(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&deep_scrub/1) |> List.to_tuple()

  defp deep_scrub(v), do: v

  defp scrub_entry(key, val), do: if(secret_key?(key), do: @redacted, else: deep_scrub(val))

  defp scrub_key(k) when is_binary(k), do: mask(k)

  defp scrub_key(k) when is_atom(k) and not is_nil(k) and not is_boolean(k) do
    scrubbed = k |> Atom.to_string() |> mask()
    if scrubbed =~ @redacted, do: scrubbed, else: k
  end

  defp scrub_key(k), do: k

  defp secret_key?(key) do
    name = if is_binary(key), do: key, else: inspect(key)
    Regex.match?(@secret_key_re, name) and not String.ends_with?(name, "_env")
  end

  defp mask(s), do: String.replace(s, @secret_value_re, @redacted)

  defp printable_charlist?([_ | _] = v), do: List.ascii_printable?(v)
  defp printable_charlist?(_), do: false

  # ── JSON-safe rendering (configs carry atoms, modules, funs, tuples) ────────

  defp safe_render(v), do: v |> deep_scrub() |> render()

  defp render(v) when is_binary(v), do: String.slice(v, 0, @max_value_chars)
  defp render(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  # inspect can surface a secret an atom smuggled past the term scrub
  # (String.to_atom(token)) — mask the rendered form as the last net.
  defp render(v) when is_atom(v), do: v |> inspect() |> mask()

  defp render(v) when is_list(v) do
    if length(v) <= 50, do: Enum.map(v, &render/1), else: inspect_bounded(v)
  end

  defp render(v) when is_map(v) do
    if map_size(v) <= 50 do
      Map.new(v, fn {k, val} -> {to_string_key(k), render(val)} end)
    else
      inspect_bounded(v)
    end
  end

  # functions, pids, tuples, refs — opaque but identifiable
  defp render(v), do: inspect_bounded(v)

  defp to_string_key(k) when is_binary(k), do: mask(k)
  defp to_string_key(k), do: k |> inspect() |> mask()

  defp inspect_bounded(v) do
    v
    |> inspect(limit: 20, printable_limit: @max_value_chars)
    |> mask()
    |> String.slice(0, @max_value_chars)
  end

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
