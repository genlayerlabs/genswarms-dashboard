# Synthetic local benchmark: MIX_ENV=test mix run scripts/snapshot_scale.exs
# No source API, database or user data is accessed.
defmodule SnapshotScale do
  alias SubzeroSwarmDashboardWeb.{SessionsLive, SnapshotView}

  def run do
    rows =
      for n <- 1..20_000 do
        %{
          "session_id" => "test:#{n}:0",
          "state" => "stored",
          "agent" => nil,
          "transport" => "test",
          "last_activity" => "2020-01-01T00:00:00Z",
          "transport_ref" => %{"chat_id" => "#{n}", "thread_id" => "0"},
          "metadata" => %{"chat_type" => "dm"},
          "user" => %{
            "handle" => "synthetic_#{n}",
            "name" => String.duplicate("Synthetic person ", 8) <> "#{n}"
          }
        }
      end

    source = %{
      "sessions" => rows,
      "extensions" => %{
        "consumers" => %{
          "count" => 20_000,
          "items" => Enum.map(rows, &%{"session_id" => &1["session_id"], "mode" => "scout"})
        }
      }
    }

    json = Jason.encode!(source)
    referenced = Jason.decode!(json)
    decoded = Jason.decode!(json, strings: :copy)

    {micros, page} =
      :timer.tc(fn -> SnapshotView.project(decoded, %{dashboard_view: SessionsLive}) end)

    unless length(page["sessions"]) == 50 and page["_sessions_page"].total == 20_000,
      do: raise("pagination changed population coverage")

    old = measure(referenced, {:snapshot, referenced})
    referenced_page = SnapshotView.project(referenced, %{dashboard_view: SessionsLive})
    projected_reference = measure(referenced_page, {:snapshot_ready, 123})
    new = measure(page, {:snapshot_ready, 123})

    unless page == referenced_page, do: raise("JSON string copying changed the projected data")

    unless new.queued.process_bytes < old.queued.process_bytes / 10,
      do: raise("snapshot amplification regression")

    unless new.one_view.referenced_binary_bytes <
             projected_reference.one_view.referenced_binary_bytes / 10,
           do: raise("projected strings retain the response buffer")

    IO.puts(
      Jason.encode!(%{
        records: 20_000,
        rows_per_view: 50,
        projection_ms: micros / 1000,
        old: old,
        projected_reference: projected_reference,
        projected: new,
        source_json_bytes: byte_size(json),
        projected_json_bytes: byte_size(Jason.encode!(page))
      })
    )
  end

  defp measure(snapshot, message) do
    owner = self()

    pid =
      spawn(fn ->
        receive do
          {:hold, value} ->
            :erlang.garbage_collect()
            send(owner, :held)
            hold(value)
        end
      end)

    monitor = Process.monitor(pid)
    send(pid, {:hold, snapshot})

    receive do
      :held -> :ok
    end

    one = memory(pid)
    for _ <- 1..12, do: send(pid, message)
    send(pid, {:barrier, self()})

    receive do
      :barrier -> :ok
    end

    queued = memory(pid)
    send(pid, {:stop, self()})

    receive do
      {:stopped, count} when count > 0 -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
    end

    %{one_view: one, queued: queued}
  end

  defp hold(snapshot) do
    receive do
      {:barrier, owner} ->
        send(owner, :barrier)
        hold(snapshot)

      {:stop, owner} ->
        send(owner, {:stopped, length(snapshot["sessions"])})
    end
  end

  defp memory(pid) do
    {:memory, process_bytes} = Process.info(pid, :memory)
    {:binary, binaries} = Process.info(pid, :binary)

    # Count each referenced buffer once. Shared binaries are not exclusive RSS.
    referenced_binary_bytes =
      binaries
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reduce(0, fn {_, size, _}, acc -> acc + size end)

    %{process_bytes: process_bytes, referenced_binary_bytes: referenced_binary_bytes}
  end
end

SnapshotScale.run()
