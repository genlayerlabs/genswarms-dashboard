defmodule GenswarmsDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :genswarms_dashboard,
      version: "0.3.5",
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

  # The dashboard embeds into both Phoenix 1.7 and 1.8 GenSwarms hosts. Keep
  # the major bound explicit; the standalone lock still pins the lowest live
  # integration lane while a host resolves its own compatible 1.x runtime.
  # Deliberately NO genswarms dep: engine calls are runtime-only remote calls; tests stub them.
  defp deps do
    [
      {:phoenix, ">= 1.7.10 and < 2.0.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.19"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
