defmodule Jc.ThreadStore do
  @moduledoc """
  Persists the console's projects + threads (conversation history) so they survive both a
  LiveView reconnect (kept in memory) and a server restart (written to disk). Agent pids are
  kept in memory but stripped on disk — a thread restored after a restart re-spawns its agent on
  the next message (the history is shown; the fresh agent starts a new context).

  The LiveView calls `put/1` with its assigns after each change and `get/0` on mount.
  Disk file: $JET_CONSOLE_STATE or ~/.jet_console.threads.
  """
  use GenServer

  @keys [:projects, :threads, :current, :current_project, :last_thread, :next, :next_project, :new_backend, :theme, :traces]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "the persisted state map (with live agent pids in memory), or nil on first run."
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "persist the LiveView's assigns (only the thread/project keys are kept)."
  def put(assigns), do: GenServer.cast(__MODULE__, {:put, Map.take(assigns, @keys)})

  defp path, do: System.get_env("JET_CONSOLE_STATE") || Path.join(System.user_home!(), ".jet_console.threads")

  @impl true
  def init(_) do
    state =
      with {:ok, bin} <- File.read(path()),
           {:ok, term} <- safe_term(bin) do
        term
      else
        _ -> nil
      end

    {:ok, state}
  end

  defp safe_term(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    _ -> :error
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:put, st}, _old) do
    File.write(path(), :erlang.term_to_binary(strip_pids(st)))
    {:noreply, st}
  end

  # disk copy has no live pids (they're meaningless across a restart)
  defp strip_pids(%{threads: threads} = st) when is_map(threads),
    do: %{st | threads: Map.new(threads, fn {id, t} -> {id, Map.put(t, :agent, nil)} end)}

  defp strip_pids(st), do: st
end
