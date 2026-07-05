defmodule GenswarmsDashboard.ConfigViewTest do
  use ExUnit.Case, async: true

  alias GenswarmsDashboard.ConfigView

  @schema %{
    "type" => "object",
    "properties" => %{
      "phone_id" => %{"type" => "string"},
      "access_token_env" => %{"type" => "string", "x-secret" => true},
      "access_token" => %{"type" => "string", "x-secret" => true},
      "templates" => %{"type" => "object", "x-mutable" => true},
      "allowed_sources" => %{"type" => "array"}
    }
  }

  defp row(rows, key), do: Enum.find(rows, &(&1.key == key))

  test "schema'd non-secret values are shown; x-mutable rides through" do
    rows =
      ConfigView.redact(
        %{phone_id: "123", templates: %{"t" => "pt_PT"}},
        @schema
      )

    assert row(rows, "phone_id").value == "123"
    refute row(rows, "phone_id").secret
    assert row(rows, "templates").value == %{"t" => "pt_PT"}
    assert row(rows, "templates").mutable
  end

  test "x-secret *_env fields show the env var NAME; literal secrets are elided" do
    rows =
      ConfigView.redact(
        %{access_token_env: "WHATSAPP_ACCESS_TOKEN", access_token: "EAAG-super-secret"},
        @schema
      )

    assert row(rows, "access_token_env").value == "WHATSAPP_ACCESS_TOKEN"
    assert row(rows, "access_token_env").secret
    assert row(rows, "access_token").value == nil
    assert row(rows, "access_token").secret
  end

  test "keys absent from the schema render name-only (fail-closed)" do
    rows = ConfigView.redact(%{mystery_key: "possibly-sensitive"}, @schema)

    assert row(rows, "mystery_key").value == nil
    refute row(rows, "mystery_key").in_schema
  end

  test "no schema at all -> every value elided" do
    rows = ConfigView.redact(%{a: 1, b: "x"}, nil)
    assert Enum.all?(rows, &(&1.value == nil))
    assert Enum.all?(rows, &(&1.in_schema == false))
  end

  test "non-JSON values (modules, funs, tuples) render bounded, never crash" do
    schema = %{"properties" => %{"client" => %{}, "now_fn" => %{}, "pair" => %{}}}

    rows =
      ConfigView.redact(
        %{client: Some.Module, now_fn: fn -> 1 end, pair: {:a, 1}},
        schema
      )

    assert row(rows, "client").value == "Some.Module"
    assert is_binary(row(rows, "now_fn").value)
    assert row(rows, "pair").value == "{:a, 1}"
    assert {:ok, _} = Jason.encode(rows)
  end

  test "build/2 assembles per-object views with handler name and has_schema flag" do
    config = %{
      objects: [
        %{name: :whatsapp, handler: Some.Module, config: %{phone_id: "1"}},
        %{name: :bare, handler: Other.Module, config: %{k: "v"}}
      ]
    }

    schema_fn = fn
      Some.Module -> @schema
      _ -> nil
    end

    view = ConfigView.build(config, schema_fn)
    [wa, bare] = view.objects

    assert wa.name == "whatsapp"
    assert wa.handler == "Some.Module"
    assert wa.has_schema
    assert Enum.find(wa.config, &(&1.key == "phone_id")).value == "1"

    refute bare.has_schema
    assert Enum.find(bare.config, &(&1.key == "k")).value == nil
  end

  test "schema_for/1 finds swarm-object.json next to the handler source and checks module binding" do
    # this module's source lives under backend/test/...; plant a schema file in a
    # tmp dir mimicking a package layout with a module that does NOT match
    tmp = Path.join(System.tmp_dir!(), "cfgview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(
      Path.join(tmp, "swarm-object.json"),
      Jason.encode!(%{module: "Not.The.Handler", config_schema: %{"properties" => %{}}})
    )

    # unknown/unloaded handler -> nil (fail-closed)
    assert ConfigView.schema_for(:not_a_module) == nil
    assert ConfigView.schema_for(nil) == nil
  after
    :ok
  end
end
