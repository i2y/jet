defmodule Jc.NativePerm do
  @moduledoc """
  Registry bridging native-Claude tool-permission requests to the Console 🔐 UI.

  A native `jet_claude` connection process registers `{token, self()}` in the public ETS table
  on open (and removes it on close). When the `claude` CLI wants to use a tool that needs
  permission, it calls the `approve` MCP tool hosted by `JcWeb.McpController`; that controller
  looks the token up here to find the owning connection process, which raises the existing
  `{:permission, ...}` event and blocks for the user's Allow/Deny. The ETS table is language-
  neutral so jet_claude (Erlang) writes it and the controller (Elixir) reads it.
  """
  use GenServer

  @table :jc_native_perm

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "the connection pid that owns `token`, or :error."
  def lookup(token) do
    case :ets.lookup(@table, token) do
      [{^token, pid}] -> {:ok, pid}
      _ -> :error
    end
  end
end
