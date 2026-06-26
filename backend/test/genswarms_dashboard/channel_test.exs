defmodule GenswarmsDashboard.ChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint GenswarmsDashboard.Endpoint

  setup_all do
    result =
      GenswarmsDashboard.start(
        swarm: "fix",
        data_source: GenswarmsDashboard.FixtureDataSource,
        pubsub_server: GenswarmsDashboard.TestPubSub,
        token: nil,
        port: "4098",
        heartbeat_ms: 50
      )

    pid =
      case result do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> :timeout
        end
      end
    end)

    :ok
  end

  setup do
    Application.put_env(:genswarms_dashboard, :stub_status, %{
      name: "fix",
      status: :running,
      started_at: ~U[2026-06-09 10:00:00Z],
      agents: [],
      objects: []
    })

    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :stub_status) end)

    {:ok, _, socket} =
      socket(GenswarmsDashboard.Socket, nil, %{})
      |> subscribe_and_join(GenswarmsDashboard.Channel, "swarm:fix")

    %{socket: socket}
  end

  test "join is gated on swarm existence; unknown topic is rejected" do
    assert {:error, %{reason: "swarm_not_found"}} =
             socket(GenswarmsDashboard.Socket, nil, %{})
             |> subscribe_and_join(GenswarmsDashboard.Channel, "swarm:ghost")

    assert {:error, %{reason: "unknown_topic"}} =
             socket(GenswarmsDashboard.Socket, nil, %{})
             |> subscribe_and_join(GenswarmsDashboard.Channel, "other:fix")
  end

  test "join degrades to OK (relay anyway) when SwarmManager.status times out" do
    # A status timeout means the swarm is UP but busy (SwarmManager blocked behind a
    # docker op) — the channel must NOT hard-error (that reconnect-loops); it joins and
    # relays via PubSub regardless. Stub status to :exit to simulate the GenServer timeout.
    Application.put_env(:genswarms_dashboard, :stub_status, fn _ -> exit(:timeout) end)
    on_exit(fn -> Application.delete_env(:genswarms_dashboard, :stub_status) end)

    assert {:ok, %{swarm: "fix"}, _socket} =
             socket(GenswarmsDashboard.Socket, nil, %{})
             |> subscribe_and_join(GenswarmsDashboard.Channel, "swarm:fix")
  end

  test "pushes a heartbeat (configurable interval)" do
    assert_push("heartbeat", %{at: at}, 1_000)
    assert is_integer(at)
  end

  test "relays PubSub events with the engine channel's names/payloads" do
    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix:status",
      {:agent_status, "agent_1", :working}
    )

    assert_push("agent_status", %{agent: "agent_1", state: :working})

    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix:routing",
      {:message_routed, %{from: "a"}}
    )

    assert_push("message_routed", %{"from" => "a"})

    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix",
      {:agent_added, "fix", :agent_9, %{model: :fast}}
    )

    assert_push("agent_added", %{name: "agent_9", spec: %{"model" => "fast"}})

    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix",
      {:topology_changed, "fix"}
    )

    assert_push("topology_changed", %{})

    Phoenix.PubSub.broadcast(GenswarmsDashboard.TestPubSub, "swarm:fix", {:swarm_stopped, "fix"})
    assert_push("swarm_stopped", %{})
  end

  test "websocket route/output relays omit message bodies and unsafe metadata" do
    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix:routing",
      {:message_routed,
       %{
         from: :tg_ingress,
         to: :telegram_conversation_runtime,
         type: :direct,
         content_preview: "secret user text",
         conversation_id: "tg:1:0",
         market_address: "0x1111111111111111111111111111111111111111",
         reason: "ok"
       }}
    )

    assert_push(
      "message_routed",
      payload = %{
        "from" => "tg_ingress",
        "to" => "telegram_conversation_runtime",
        "type" => "direct",
        "reason" => "ok"
      }
    )

    refute inspect(payload) =~ "secret user text"
    refute inspect(payload) =~ "tg:1:0"
    refute inspect(payload) =~ "0x111111"

    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix:output",
      {:agent_output, :agent_9, "agent reply with secret"}
    )

    assert_push("agent_output", %{agent: "agent_9"})
    refute_push("agent_output", %{content: "agent reply with secret"}, 100)
  end

  test "agent_added websocket payload redacts backend secrets, skills, and host paths" do
    spec = %{
      name: :agent_9,
      model: :fast,
      skills: [
        %{name: "SOUL.md", path: "/Users/albert/szc-workspace/tg:1:0/SOUL.md"},
        "/tmp/mm-tg_1_0/private.md"
      ],
      config: %{
        workspace: "/Users/albert/szc-workspace/tg:1:0",
        llm_proxy: %{api_key: "opaque-router-token"}
      },
      backend:
        {:bwrap,
         %{
           workspace: "/tmp/mm-tg_1_0",
           api_key: "opaque-router-token",
           endpoint: "http://127.0.0.1:4318/v1/chat/completions",
           extra_env: %{"OPENAI_API_KEY" => "sk-upstream", "SUBZEROCLAW_AGENT_NAME" => "agent_9"},
           memory_limit: "32M",
           cpu_shares: 1,
           tasks_max: 50
         }}
    }

    Phoenix.PubSub.broadcast(
      GenswarmsDashboard.TestPubSub,
      "swarm:fix",
      {:agent_added, "fix", :agent_9, spec}
    )

    assert_push(
      "agent_added",
      payload = %{
        name: "agent_9",
        spec: %{
          "name" => "agent_9",
          "model" => "fast",
          "backend" => %{
            "type" => "bwrap",
            "opts" => %{"memory_limit" => "32M", "cpu_shares" => 1, "tasks_max" => 50}
          }
        }
      }
    )

    refute inspect(payload) =~ "opaque-router-token"
    refute inspect(payload) =~ "/tmp/mm-tg_1_0"
    refute inspect(payload) =~ "/Users/albert"
    refute inspect(payload) =~ "skills"
    refute inspect(payload) =~ "llm_proxy"
    refute inspect(payload) =~ "OPENAI_API_KEY"
  end

  test "has no write path: any inbound event is ignored", %{socket: socket} do
    ref = push(socket, "send_task", %{cmd: "rm -rf"})
    refute_reply(ref, :ok, _, 200)
  end
end
