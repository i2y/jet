defmodule Jc.TurnBuffer do
  @moduledoc """
  Decouples a running turn's event stream from the LiveView's lifecycle, so a turn SURVIVES a
  browser reload. The turn process (jet_console's `run_to_tagged`) sends its tagged events HERE
  instead of straight to the LiveView. This server:

    * BUFFERS each thread's events (reset when a new turn starts on that thread), and
    * FORWARDS them to whichever LiveView is currently subscribed.

  On (re)mount the LiveView subscribes (becoming the forward target) and gets the buffers back to
  replay — reconnecting to any turn still in flight. A turn is an independent BEAM process, so it
  keeps running across the reload; only its event delivery had been tied to the dead LiveView.
  """
  use GenServer

  def start_link(_),
    do: GenServer.start_link(__MODULE__, %{sub: nil, bufs: %{}}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @doc "a new turn started on `tid` -> clear its buffer."
  def start_turn(tid), do: GenServer.cast(__MODULE__, {:start, tid})

  @doc """
  Become the forward target. The given `tids` (the threads the caller still considers RUNNING) have
  their buffered messages re-sent to `pid` IN ORDER right now — before any further live event is
  forwarded — so the caller replays them through its normal message path with no race and no dup.
  """
  def subscribe(pid, tids), do: GenServer.call(__MODULE__, {:sub, pid, tids})

  @doc "drop a thread's buffer (e.g. when the thread is deleted)."
  def forget(tid), do: GenServer.cast(__MODULE__, {:forget, tid})

  @doc "the pid to hand a turn so its events route through here."
  def target, do: Process.whereis(__MODULE__)

  @impl true
  def handle_cast({:start, tid}, s), do: {:noreply, %{s | bufs: Map.put(s.bufs, tid, [])}}
  def handle_cast({:forget, tid}, s), do: {:noreply, %{s | bufs: Map.delete(s.bufs, tid)}}

  @impl true
  def handle_call({:sub, pid, tids}, _from, s) do
    for tid <- tids, msg <- Map.get(s.bufs, tid, []), do: send(pid, msg)
    {:reply, :ok, %{s | sub: pid}}
  end

  @impl true
  def handle_info({:jet_event_tag, tid, _} = msg, s), do: {:noreply, route(tid, msg, s)}
  def handle_info({:jet_done_tag, tid, _} = msg, s), do: {:noreply, route(tid, msg, s)}
  def handle_info(_other, s), do: {:noreply, s}

  defp route(tid, msg, s) do
    if is_pid(s.sub), do: send(s.sub, msg)
    %{s | bufs: Map.update(s.bufs, tid, [msg], &(&1 ++ [msg]))}
  end
end
