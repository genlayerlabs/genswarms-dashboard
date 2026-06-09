defmodule GenswarmsDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :genswarms_dashboard,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Versions pinned NEAR the genswarms engine's mix.lock (phoenix 1.7.21, bandit 1.10.3,
  # plug 1.19.1, jason 1.4.4) — at runtime this code compiles against the engine BEAM's
  # already-loaded deps, so standalone tests should see the same API surface.
  # Deliberately NO genswarms dep: engine calls are runtime-only remote calls; tests stub them.
  defp deps do
    [
      {:phoenix, "~> 1.7.10"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"}
    ]
  end
end
