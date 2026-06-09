# Minimal stand-ins for the genswarms engine modules the library calls at runtime.
# The real engine is NOT a dependency of this repo (calls are runtime-only remote calls
# into the host BEAM); tests steer these via Application env under :genswarms_dashboard.
# Compiled ONLY in the test env (see elixirc_paths in mix.exs).
defmodule Genswarms.SwarmManager do
  def status(name) do
    case Application.get_env(:genswarms_dashboard, :stub_status) do
      nil -> {:error, :not_found}
      fun when is_function(fun, 1) -> fun.(name)
      status when is_map(status) -> {:ok, status}
    end
  end
end

defmodule Genswarms.Routing.Router do
  def get_topology(_name), do: Application.get_env(:genswarms_dashboard, :stub_topology, [])
end

defmodule Genswarms.Observability.LogStore do
  def query(opts) do
    # record the opts so tests can assert the query the plug built
    Application.put_env(:genswarms_dashboard, :stub_last_events_query, opts)
    Application.get_env(:genswarms_dashboard, :stub_events, [])
  end
end

defmodule Genswarms.Agents.AgentServer do
  def get_logs(_swarm, slot) do
    case Application.get_env(:genswarms_dashboard, :stub_logs) do
      fun when is_function(fun, 1) -> fun.(slot)
      other -> other
    end
  end
end
