defmodule SubzeroSwarmDashboard.TopologyOverlay do
  @moduledoc """
  Host topology overlay from the environment.

  The topology canvas reads four optional app-env keys (README "Host overlay
  configuration"): `:node_groups`, `:object_descriptions`, `:node_aliases`,
  `:ext_endpoints`. A host sets them WITHOUT touching files inside this
  package by handing the same data as JSON:

    * `DASHBOARD_TOPOLOGY_OVERLAY` — inline JSON object (takes precedence);
    * `DASHBOARD_TOPOLOGY_OVERLAY_FILE` — path to a JSON file.

  The Dockerfile bakes `DASHBOARD_TOPOLOGY_OVERLAY` from a build-arg so an
  image-building host can ship its overlay inside the image; a runtime env var
  of the same name overrides the baked value.

  Shape errors reject the WHOLE overlay with a reason (runtime.exs warns and
  keeps the compiled defaults) — a half-applied overlay would look like a
  canvas bug rather than a config bug.
  """

  @keys %{
    "node_groups" => :node_groups,
    "object_descriptions" => :object_descriptions,
    "node_aliases" => :node_aliases,
    "ext_endpoints" => :ext_endpoints
  }

  @doc "Overlay from an env map (defaults to the process environment)."
  @spec from_env(%{optional(String.t()) => String.t()}) :: {:ok, keyword()} | {:error, String.t()}
  def from_env(env \\ System.get_env()) do
    inline = present(env["DASHBOARD_TOPOLOGY_OVERLAY"])
    file = present(env["DASHBOARD_TOPOLOGY_OVERLAY_FILE"])

    cond do
      inline ->
        parse(inline)

      file ->
        case File.read(file) do
          {:ok, json} -> parse(json)
          {:error, reason} -> {:error, "cannot read #{file}: #{:file.format_error(reason)}"}
        end

      true ->
        {:ok, []}
    end
  end

  @doc "Parse an overlay JSON object into the app-env keyword it configures."
  @spec parse(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> build(map)
      {:ok, other} -> {:error, "overlay must be a JSON object, got #{inspect(other)}"}
      {:error, err} -> {:error, "invalid JSON: #{Exception.message(err)}"}
    end
  end

  defp build(map) do
    Enum.reduce_while(map, {:ok, []}, fn {k, v}, {:ok, acc} ->
      case Map.fetch(@keys, k) do
        {:ok, key} ->
          case coerce(key, v) do
            {:ok, value} -> {:cont, {:ok, acc ++ [{key, value}]}}
            :error -> {:halt, {:error, "#{k}: #{shape(key)}"}}
          end

        :error ->
          {:halt,
           {:error, "unknown key #{inspect(k)} (known: #{Enum.join(Map.keys(@keys), ", ")})"}}
      end
    end)
  end

  defp coerce(:node_groups, %{} = groups) do
    ok? =
      Enum.all?(groups, fn {g, members} ->
        is_binary(g) and is_list(members) and Enum.all?(members, &is_binary/1)
      end)

    if ok?, do: {:ok, groups}, else: :error
  end

  defp coerce(:object_descriptions, %{} = descs) do
    if Enum.all?(descs, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      # the dynamic agent chips read the :agent ATOM key (see TopologyLive)
      {:ok,
       Map.new(descs, fn
         {"agent", v} -> {:agent, v}
         pair -> pair
       end)}
    else
      :error
    end
  end

  defp coerce(:node_aliases, %{} = aliases) do
    if Enum.all?(aliases, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, aliases},
      else: :error
  end

  defp coerce(:ext_endpoints, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error
  end

  defp coerce(_key, _value), do: :error

  defp shape(:node_groups), do: ~s(expected {"group": ["member", ...]})
  defp shape(:object_descriptions), do: ~s(expected {"node": "text"})
  defp shape(:node_aliases), do: ~s(expected {"vocab_name": "real_name"})
  defp shape(:ext_endpoints), do: ~s(expected ["name", ...])

  defp present(nil), do: nil

  defp present(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end
end
