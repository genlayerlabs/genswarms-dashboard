defmodule GenswarmsDashboard.Extensions do
  @moduledoc """
  The dashboard's PLUGIN CONTRACT (schema 1) and the provider-merge helper.

  ## The contract

  Any package/object can contribute to the dashboard WITHOUT a compile-time
  dependency on it (peer-contract-as-data, the stack's discipline): it exports

      def dashboard_extension(opts \\\\ []) do
        %{
          "my_key" => %{...summary data...},
          "dashboard_pages" => [
            %{
              "schema" => 1,                       # optional; absent ⇒ 1
              "id" => "my-page",                   # [a-zA-Z0-9][a-zA-Z0-9_-]{0,63}
              "label" => "My page",
              "icon" => "hero-puzzle-piece",       # optional heroicon name
              "meta" => "free-form subtitle",      # optional
              "sections" => [
                %{"type" => "metrics", "title" => "…", "items" => [%{"label" => …, "value" => …}]},
                %{"type" => "table", "title" => "…",
                  "columns" => [%{"key" => "k", "label" => "…", "align" => "right", "mono" => true}],
                  "rows" => [%{"k" => …}]}
              ]
            }
          ]
        }
      end

  and the HOST's `DataSource.snapshot/1` merges it into `extensions` via
  `collect/1`. Everything is display DATA: the renderer ignores unknown or
  malformed blocks and caps collections (an extension can never crash or
  overwhelm the shell). A page whose `"schema"` is greater than the dashboard's
  supported version is skipped — forward-compatible by omission.

  The reference implementation of a provider is genswarms-llm-proxy's
  `dashboard_extension/1`.
  """

  @schema 1

  @doc "The extension-contract schema version this dashboard speaks."
  def schema, do: @schema

  @doc """
  Merge the extension maps of `providers` into ONE `extensions` map for
  `DataSource.snapshot/1`.

  A provider is a module exporting `dashboard_extension/1` (called with `opts`),
  or a ready-made map. Guarded like every cross-package seam: a missing module,
  a missing export, or a raising provider contributes nothing (fail-open —
  observability must never take the swarm down).

  Merge rules: scalar/summary keys are merged last-wins; `"dashboard_pages"`
  CONCATENATE across providers, first occurrence of an `"id"` wins.
  """
  @spec collect([module() | map()], keyword()) :: %{optional(String.t()) => term()}
  def collect(providers, opts \\ []) when is_list(providers) do
    providers
    |> Enum.map(&provider_extension(&1, opts))
    |> Enum.reduce(%{}, &merge/2)
  end

  defp provider_extension(%{} = ready, _opts), do: ready

  defp provider_extension(mod, opts) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :dashboard_extension, 1) do
      mod.dashboard_extension(opts)
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp provider_extension(_, _), do: %{}

  defp merge(%{} = ext, acc) do
    {pages, rest} = Map.pop(ext, "dashboard_pages", [])

    acc
    |> Map.merge(rest)
    |> Map.update("dashboard_pages", List.wrap(pages), &(&1 ++ List.wrap(pages)))
    |> dedupe_pages()
  end

  defp merge(_other, acc), do: acc

  defp dedupe_pages(%{"dashboard_pages" => pages} = ext) when is_list(pages) do
    %{ext | "dashboard_pages" => Enum.uniq_by(pages, &page_id/1)}
  end

  defp dedupe_pages(ext), do: ext

  defp page_id(%{"id" => id}), do: id
  defp page_id(other), do: other
end
