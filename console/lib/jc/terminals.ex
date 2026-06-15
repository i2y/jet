defmodule Jc.Terminals do
  @moduledoc """
  Owns the per-thread PTY ports + their scrollback OUTSIDE the LiveView, so a terminal survives a
  browser reload (the LiveView re-mounts; the shell keeps running). The LiveView attaches on mount
  to become the output target and replays each terminal's buffer into its fresh xterm.

  State: %{sub: pid | nil, terms: %{tid => %{port, buf}}}.
  """
  use GenServer

  @cap 200_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{sub: nil, terms: %{}}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @doc "LiveView (re)mount: become the live-output target; returns %{tid => buffer} for existing terminals."
  def attach(pid), do: GenServer.call(__MODULE__, {:attach, pid})

  @doc "ensure a PTY exists for tid (spawn in cwd at cols×rows if not); returns its scrollback to replay."
  def ensure(tid, cwd, cols \\ 120, rows \\ 30), do: GenServer.call(__MODULE__, {:ensure, tid, cwd, cols, rows})

  def input(tid, data), do: GenServer.cast(__MODULE__, {:input, tid, data})
  def close(tid), do: GenServer.cast(__MODULE__, {:close, tid})

  @doc "(kept for the client; a no-op — the PTY is sized once at spawn, see ensure/4)."
  def resize(tid, cols, rows), do: GenServer.cast(__MODULE__, {:resize, tid, cols, rows})

  @impl true
  def handle_call({:attach, pid}, _from, s) do
    {:reply, Map.new(s.terms, fn {tid, t} -> {tid, t.buf} end), %{s | sub: pid}}
  end

  def handle_call({:ensure, tid, cwd, cols, rows}, _from, s) do
    case Map.get(s.terms, tid) do
      %{buf: buf} ->
        {:reply, buf, s}

      nil ->
        shell = System.get_env("SHELL") || "/bin/bash"
        c = if is_integer(cols) and cols > 0, do: cols, else: 120
        r = if is_integer(rows) and rows > 0, do: rows, else: 30
        # set the PTY winsize ONCE, BEFORE the shell starts (stty runs in the throwaway sh, then
        # exec replaces it with the shell on the same already-sized PTY) -- so nothing leaks into a
        # foreground program later. `script` gives the PTY; it has no winsize control of its own.
        port =
          Port.open({:spawn_executable, "/usr/bin/script"},
            [:binary, :exit_status, {:cd, cwd},
             args: ["-q", "/dev/null", "/bin/sh", "-c", "stty cols #{c} rows #{r}; exec #{shell}"]])

        {:reply, "", %{s | terms: Map.put(s.terms, tid, %{port: port, buf: ""})}}
    end
  end

  @impl true
  def handle_cast({:input, tid, data}, s) do
    case Map.get(s.terms, tid) do
      %{port: port} -> try do Port.command(port, data) rescue _ -> :ok end
      _ -> :ok
    end

    {:noreply, s}
  end

  # Live resize, the SAFE way: set the winsize on the PTY DEVICE directly (`stty -f /dev/ttysNNN`),
  # which is an out-of-band ioctl — it never touches the data stream, so it can't leak into a
  # running foreground program (the kernel just sends SIGWINCH to it so it reflows). No new
  # dependency: `stty`/`pgrep`/`ps` are standard. The device is found once (script's child shell's
  # tty) and cached on the term.
  def handle_cast({:resize, tid, cols, rows}, s)
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 do
    case Map.get(s.terms, tid) do
      %{port: port} = t when is_port(port) ->
        dev = Map.get(t, :dev) || pty_device(port)

        if dev do
          System.cmd("stty", [stty_flag(), dev, "cols", Integer.to_string(cols), "rows", Integer.to_string(rows)],
            stderr_to_stdout: true)
        end

        {:noreply, %{s | terms: Map.put(s.terms, tid, Map.put(t, :dev, dev))}}

      _ ->
        {:noreply, s}
    end
  end

  def handle_cast({:resize, _tid, _cols, _rows}, s), do: {:noreply, s}

  def handle_cast({:close, tid}, s) do
    case Map.get(s.terms, tid) do
      %{port: port} -> try do Port.close(port) rescue _ -> :ok end
      _ -> :ok
    end

    {:noreply, %{s | terms: Map.delete(s.terms, tid)}}
  end

  # the PTY slave device of the shell `script` spawned: script's os_pid -> its child shell pid ->
  # that pid's controlling tty (e.g. "ttys006" -> /dev/ttys006, or Linux "pts/3" -> /dev/pts/3).
  defp pty_device(port) do
    with {:os_pid, spid} <- :erlang.port_info(port, :os_pid),
         {child, 0} <- System.cmd("pgrep", ["-P", Integer.to_string(spid)], stderr_to_stdout: true),
         shpid when shpid != "" <- child |> String.split() |> List.first(),
         {tty, 0} <- System.cmd("ps", ["-o", "tty=", "-p", shpid], stderr_to_stdout: true),
         tty = String.trim(tty),
         true <- tty != "" and tty != "??" and tty != "?" do
      "/dev/" <> tty
    else
      _ -> nil
    end
  end

  defp stty_flag do
    case :os.type() do
      {:unix, :darwin} -> "-f"   # BSD stty: operate on the given file/device
      _ -> "-F"                  # GNU stty (Linux)
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, s) when is_port(port), do: {:noreply, out(s, port, data)}

  def handle_info({port, {:exit_status, _}}, s) when is_port(port),
    do: {:noreply, out(s, port, "\r\n[shell exited]\r\n")}

  def handle_info(_other, s), do: {:noreply, s}

  defp out(s, port, data) do
    case Enum.find(s.terms, fn {_tid, t} -> t.port == port end) do
      {tid, t} ->
        if is_pid(s.sub), do: send(s.sub, {:term_out, tid, data})
        %{s | terms: Map.put(s.terms, tid, %{t | buf: cap(t.buf <> data)})}

      nil ->
        s
    end
  end

  defp cap(buf) when byte_size(buf) > @cap, do: binary_part(buf, byte_size(buf) - @cap, @cap)
  defp cap(buf), do: buf
end
