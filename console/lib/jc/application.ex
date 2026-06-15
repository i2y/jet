defmodule Jc.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # resolve the Jet repo root ONCE at boot (cwd is the console/ dir then; it changes per-thread
    # later) and cache it. Defaults to the parent of console/ (i.e. the cloned jet repo); override
    # with JET_ROOT. No machine-specific path is baked in.
    :persistent_term.put({:jc, :jet_root}, System.get_env("JET_ROOT") || Path.expand(".."))

    add_jet_code_paths()
    Jc.Settings.apply_env()      # point jet_settings' env vars at the user's saved config before agents spawn
    Jc.AgentBuilder.regenerate() # (re)generate custom_agents.jet from saved configs, then load all agents
    set_mcp_base()               # tell native jet_claude where to point claude's permission MCP tool

    children = [
      JcWeb.Telemetry,
      Jc.ThreadStore,
      Jc.TurnBuffer,
      Jc.Terminals,
      Jc.NativePerm,
      {DNSCluster, query: Application.get_env(:jc, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Jc.PubSub},
      # Start a worker by calling: Jc.Worker.start_link(arg)
      # {Jc.Worker, arg},
      # Start to serve requests, typically the last entry
      JcWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Jc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # native jet_claude reads JET_CONSOLE_MCP_BASE to build claude's --mcp-config (the permission
  # tool's URL). Unset -> the native backend skips the bridge and uses --permission-mode acceptEdits.
  defp set_mcp_base do
    port =
      System.get_env("PORT") ||
        to_string(get_in(Application.get_env(:jc, JcWeb.Endpoint) || [], [:http, :port]) || 4000)

    System.put_env("JET_CONSOLE_MCP_BASE", "http://127.0.0.1:#{port}")
  end

  # make the Jet agent beams loadable: the .jet stdlib (src), the demo (examples), and the
  # FFI + gleam/gun deps (build/erlang-shipment/*/ebin).
  defp add_jet_code_paths do
    jet = Jc.AgentStore.jet_root()

    ([Path.join(jet, "src"), Path.join(jet, "examples")] ++
       Path.wildcard(Path.join(jet, "build/erlang-shipment/*/ebin")))
    |> Enum.each(&Code.append_path(String.to_charlist(&1)))
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
