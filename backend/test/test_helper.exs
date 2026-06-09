# A real Phoenix.PubSub for channel/endpoint tests. Named like the engine's so the
# injected `pubsub_server:` config path is exercised with a realistic atom.
{:ok, _} = Supervisor.start_link(
  [{Phoenix.PubSub, name: GenswarmsDashboard.TestPubSub}],
  strategy: :one_for_one
)

ExUnit.start()
