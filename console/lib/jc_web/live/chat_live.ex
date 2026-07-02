defmodule JcWeb.ChatLive do
  @moduledoc "Jet Console — the agent-panel LiveView. Agents come from editable .jet files (Jc.AgentStore); the picker is their aggregated catalog, hot-reloaded on save."
  use JcWeb, :live_view
  alias Jc.AgentStore

  @impl true
  def mount(_params, _session, socket) do
    conn = connected?(socket)
    if conn, do: cd_to(AgentStore.jet_root())
    agents = AgentStore.catalog()
    base = normalize_threads(Jc.ThreadStore.get() || fresh_state(agents, conn))
    socket = assign(socket, Map.merge(base, %{agents: agents, editing: nil, proj_error: nil, renaming: nil, pending_perm: nil, context: nil, files: nil, settings: nil, builder: nil, board: false, terminals: %{}, structure: nil, traces: Map.get(base, :traces, %{}), dock_tab: :terminal, acp_commands: (case Map.get(base, :acp_commands) do m when is_map(m) -> m; _ -> %{} end), theme: Map.get(base, :theme, :light)}))
    {:ok, if(conn, do: reconnect_turns(socket), else: socket)}
  end

  # On a connected (re)mount, subscribe to the turn buffer and replay any in-flight turn's events,
  # so a reload RECONNECTS to a running session (the turn kept running) instead of leaving it frozen.
  defp reconnect_turns(socket) do
    running = for {tid, t} <- socket.assigns.threads, t.running, do: {tid, t}

    threads =
      Enum.reduce(running, socket.assigns.threads, fn {tid, t}, acc ->
        Map.put(acc, tid, %{t | blocks: blocks_to_last_user(t.blocks)})
      end)

    traces = Enum.reduce(running, socket.assigns.traces, fn {tid, _}, acc -> Map.put(acc, tid, []) end)
    Jc.TurnBuffer.subscribe(self(), Enum.map(running, fn {tid, _} -> tid end))
    terms = Jc.Terminals.attach(self())   # PTYs survive the reload; the current thread's xterm replays on mount
    assign(socket, threads: threads, traces: traces, terminals: Map.new(terms, fn {tid, _buf} -> {tid, %{}} end))
  end

  # roll a running thread's blocks back to its current turn's user message, so replaying the buffer
  # rebuilds the reply cleanly (no doubled text) even if a mid-turn commit saved a partial one.
  defp blocks_to_last_user(blocks) do
    case blocks |> Enum.with_index() |> Enum.filter(fn {b, _} -> b.type == :user end) |> List.last() do
      {_b, idx} -> Enum.take(blocks, idx + 1)
      nil -> blocks
    end
  end

  # Threads restored from an older ThreadStore may lack newer fields. Fill them so a map-update
  # (`%{t | worktree: ...}`) or a `t.run_pid` access can't raise KeyError and crash the LiveView
  # (a crash drops the socket AND kills any in-flight agent run — e.g. a slow Claude Code reply).
  defp normalize_threads(%{threads: threads} = base),
    do: %{base | threads: Map.new(threads, fn {id, t} -> {id, normalize_thread(t)} end)}

  defp normalize_threads(base), do: base

  defp normalize_thread(t),
    do:
      Map.merge(
        %{running: false, run_pid: nil, carry: false, worktree: nil, agent: nil, turn_usage: nil, usage_total: %{}},
        t
      )

  defp fresh_state(agents, conn) do
    default = default_backend(agents)
    t = %{new_thread(1, 1, default, conn) | blocks: [start_marker(default, agents)]}

    %{projects: %{1 => %{id: 1, name: Path.basename(AgentStore.jet_root()), dir: AgentStore.jet_root()}},
      current_project: 1, next_project: 2,
      threads: %{1 => t},
      current: 1, next: 2, new_backend: default}
  end

  defp cd_to(dir), do: if(is_binary(dir) and File.dir?(dir), do: File.cd!(dir))

  defp project_dir(projects, pid) do
    case projects[pid] do
      %{dir: d} -> d
      _ -> nil
    end
  end

  defp default_backend([{m, k, _} | _]), do: "#{m}:#{k}"
  defp default_backend(_), do: "builtin:local"

  defp new_thread(id, project_id, backend, spawn?) do
    %{id: id, project_id: project_id, title: "New thread", backend: backend, blocks: [],
      running: false, run_pid: nil, carry: false, worktree: nil, turn_usage: nil, usage_total: %{},
      agent: if(spawn?, do: do_spawn(backend), else: nil)}
  end

  # where a thread's agent runs: its isolated git worktree if set, else the project folder.
  defp thread_cwd(t, projects) do
    case Map.get(t, :worktree) do
      %{path: p} -> p
      _ -> project_dir(projects, t.project_id)
    end
  end

  defp do_spawn(backend) do
    case String.split(backend, ":", parts: 2) do
      [mod, key] ->
        try do
          AgentStore.spawn_agent(String.to_existing_atom(mod), String.to_existing_atom(key))
        rescue
          _ -> nil
        end

      _ -> nil
    end
  end

  defp backend_label(backend, agents),
    do: Enum.find_value(agents, backend, fn {m, k, l} -> "#{m}:#{k}" == backend && l end)

  defp start_marker(backend, agents),
    do: %{type: :marker, text: "— " <> backend_label(backend, agents) <> " —"}

  # persist the thread/project state (survives reconnect + restart) and reply.
  defp commit(socket) do
    Jc.ThreadStore.put(socket.assigns)
    {:noreply, socket}
  end

  # re-spawn a thread's agent if it was lost (restored from disk after a restart, or it died).
  defp ensure_agent(%{agent: pid} = t) when is_pid(pid) do
    if Process.alive?(pid), do: t, else: %{t | agent: do_spawn(t.backend)}
  end

  defp ensure_agent(t), do: %{t | agent: do_spawn(t.backend)}

  # --- thread/project events ----------------------------------------------
  @impl true
  def handle_event("set_backend", %{"backend" => b}, socket),
    do: commit(assign(socket, new_backend: b))

  def handle_event("toggle_theme", _p, socket),
    do: commit(assign(socket, theme: if(socket.assigns.theme == :dark, do: :light, else: :dark)))

  # switch the CURRENT thread's agent mid-conversation: kill the old agent, mark the switch, and
  # flag the next message to carry the conversation history to the new agent.
  def handle_event("switch_backend", %{"backend" => b}, socket) do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]

    if t == nil or t.backend == b do
      {:noreply, socket}
    else
      stop_pids(t)
      marker = %{type: :marker, text: "— switched to #{backend_label(b, socket.assigns.agents)} —"}
      t = %{t | backend: b, agent: nil, run_pid: nil, running: false, carry: true, blocks: t.blocks ++ [marker]}
      commit(maybe_reprobe_structure(probe_current_commands(assign(socket, threads: Map.put(socket.assigns.threads, cur, t), new_backend: b))))
    end
  end

  def handle_event("new_thread", _p, socket) do
    id = socket.assigns.next
    t = new_thread(id, socket.assigns.current_project, socket.assigns.new_backend, true)
    t = %{t | blocks: [start_marker(t.backend, socket.assigns.agents)]}
    commit(maybe_reprobe_structure(probe_current_commands(assign(socket, threads: Map.put(socket.assigns.threads, id, t), current: id, next: id + 1))))
  end

  def handle_event("new_project", %{"dir" => dir}, socket) do
    d = String.trim(dir)

    cond do
      d == "" ->
        {:noreply, assign(socket, proj_error: "enter a directory path or owner/repo")}

      # `owner/repo` or a GitHub URL -> clone it with `gh` and open the clone as a project
      ref = clone_ref(d) ->
        if gh_path() do
          start_clone(socket, ref)
        else
          {:noreply, assign(socket, proj_error: "install the GitHub CLI (gh) to clone #{ref}, or enter a directory path")}
        end

      true ->
        # resolve a RELATIVE path against a stable base (the user's home), NOT the BEAM cwd — the
        # console mutates cwd per-thread via File.cd! (node-global), so a relative path would
        # otherwise be created inside whatever project is currently open. Absolute / "~/…" unaffected.
        expanded = Path.expand(d, System.user_home() || Jc.AgentStore.jet_root())

        cond do
          File.regular?(expanded) ->
            {:noreply, assign(socket, proj_error: "not a directory: #{d}")}

          # an existing dir, or a new one we can create (open a project in a brand-new directory)
          File.dir?(expanded) or File.mkdir_p(expanded) == :ok ->
            add_project(socket, expanded)

          true ->
            {:noreply, assign(socket, proj_error: "could not create directory: #{d}")}
        end
    end
  end

  # add `dir` as a new project, make it current, persist.
  defp add_project(socket, dir) do
    id = socket.assigns.next_project
    cd_to(dir)

    commit(
      assign(socket,
        projects: Map.put(socket.assigns.projects, id, %{id: id, name: Path.basename(dir), dir: dir}),
        current_project: id, next_project: id + 1, current: nil, proj_error: nil))
  end

  # A GitHub repo reference typed into "new project" -> the arg for `gh repo clone` (a github URL or
  # the bare owner/repo shorthand), or nil for an ordinary path. The shorthand is exactly one slash
  # and no leading "/", "~" or "." — so "~/a/b" and "/a/b" stay local directory paths.
  defp clone_ref(d) do
    cond do
      Regex.match?(~r{^(https?://|git@)\S+}, d) and String.contains?(d, "github") -> d
      # owner/repo: owner starts with an alnum/underscore (so "./x", "../x", "-x/y" stay local paths)
      Regex.match?(~r{^\w[\w.-]*/[\w.-]+$}, d) -> d
      true -> nil
    end
  end

  defp gh_path, do: System.find_executable("gh")

  # clone in the background (so the UI never freezes) into ~/<repo>, then message the result back.
  defp start_clone(socket, ref) do
    base = System.user_home() || Jc.AgentStore.jet_root()
    name = ref |> String.split(["/", ":"], trim: true) |> List.last() |> String.replace_suffix(".git", "")
    dest = Path.join(base, name)
    me = self()

    if File.exists?(dest) do
      {:noreply, assign(socket, proj_error: "#{dest} already exists — open it as a directory instead")}
    else
      Task.start(fn ->
        res = System.cmd(gh_path() || "gh", ["repo", "clone", ref, dest], stderr_to_stdout: true)
        send(me, {:clone_done, ref, dest, res})
      end)

      {:noreply, assign(socket, proj_error: "cloning #{ref} → #{dest} …")}
    end
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    pid = String.to_integer(id)
    cd_to(socket.assigns.projects[pid][:dir])
    commit(assign(socket, current_project: pid, current: first_thread_of(socket.assigns.threads, pid)))
  end

  def handle_event("select", %{"id" => id}, socket),
    do: commit(maybe_reprobe_structure(probe_current_commands(assign(socket, current: String.to_integer(id)))))

  # P2 — the parallel-agents board (a grid of thread cards; click one to open it).
  def handle_event("toggle_board", _p, socket), do: {:noreply, assign(socket, board: not socket.assigns.board)}

  def handle_event("board_open", %{"id" => id}, socket),
    do: commit(maybe_reprobe_structure(probe_current_commands(assign(socket, current: String.to_integer(id), board: false))))

  def handle_event("rename_start", %{"id" => id}, socket),
    do: {:noreply, assign(socket, renaming: String.to_integer(id))}

  def handle_event("rename_thread", %{"id" => id, "title" => title}, socket) do
    tid = String.to_integer(id)
    title = String.trim(title)
    socket = if title == "", do: socket, else: update_thread(socket, tid, fn t -> %{t | title: title} end)
    commit(assign(socket, renaming: nil))
  end

  def handle_event("del_thread", %{"id" => id}, socket) do
    tid = String.to_integer(id)
    t = socket.assigns.threads[tid]
    if t, do: stop_pids(t)
    if t && Map.get(t, :worktree), do: Jc.Worktree.discard(project_dir(socket.assigns.projects, t.project_id), t.worktree)

    if Map.has_key?(socket.assigns.terminals, tid), do: Jc.Terminals.close(tid)

    threads = Map.delete(socket.assigns.threads, tid)

    current =
      if socket.assigns.current == tid,
        do: first_thread_of(threads, socket.assigns.current_project),
        else: socket.assigns.current

    commit(assign(socket, threads: threads, terminals: Map.delete(socket.assigns.terminals, tid), current: current, renaming: nil))
  end

  # remove a project from the list. Its threads are closed (agents stopped, worktrees discarded,
  # terminals closed); the project's FOLDER ON DISK is left untouched.
  def handle_event("remove_project", %{"id" => id}, socket) do
    pid = String.to_integer(id)
    dir = socket.assigns.projects[pid][:dir]

    doomed = socket.assigns.threads |> Map.values() |> Enum.filter(&(&1.project_id == pid))

    Enum.each(doomed, fn t ->
      stop_pids(t)
      if Map.get(t, :worktree), do: Jc.Worktree.discard(dir, t.worktree)
      if Map.has_key?(socket.assigns.terminals, t.id), do: Jc.Terminals.close(t.id)
    end)

    doomed_ids = Enum.map(doomed, & &1.id)
    threads = Map.drop(socket.assigns.threads, doomed_ids)
    terminals = Map.drop(socket.assigns.terminals, doomed_ids)
    projects = Map.delete(socket.assigns.projects, pid)

    current_project =
      if socket.assigns.current_project == pid do
        case by_id(projects) do
          [p | _] -> p.id
          [] -> nil
        end
      else
        socket.assigns.current_project
      end

    current =
      if socket.assigns.current in doomed_ids,
        do: first_thread_of(threads, current_project),
        else: socket.assigns.current

    cd_to(if current_project, do: projects[current_project][:dir])

    commit(
      assign(socket,
        projects: projects, threads: threads, terminals: terminals,
        current_project: current_project, current: current, proj_error: nil))
  end

  def handle_event("stop", _p, socket) do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]

    if t == nil do
      {:noreply, socket}
    else
      stop_pids(t)
      commit(update_thread(socket, cur, fn x -> %{x | running: false, run_pid: nil, agent: nil} end))
    end
  end

  # --- git worktree isolation (opt-in, per thread) ------------------------
  def handle_event("isolate", _p, socket) do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]

    cond do
      t == nil or Map.get(t, :worktree) ->
        {:noreply, socket}

      true ->
        case Jc.Worktree.create(project_dir(socket.assigns.projects, t.project_id), cur) do
          {:ok, wt} ->
            stop_pids(t)   # re-spawn in the worktree (fresh cwd) on the next send
            marker = %{type: :marker, text: "🌳 isolated on #{wt.branch}"}
            t = %{t | worktree: wt, agent: nil, run_pid: nil, running: false, blocks: t.blocks ++ [marker]}
            commit(assign(socket, threads: Map.put(socket.assigns.threads, cur, t)))

          {:error, msg} ->
            commit(update_thread(socket, cur, fn x -> %{x | blocks: x.blocks ++ [%{type: :marker, text: "🌳 cannot isolate: #{msg}"}]} end))
        end
    end
  end

  def handle_event("merge_wt", _p, socket) do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]
    wt = t && Map.get(t, :worktree)

    if wt == nil do
      {:noreply, socket}
    else
      text =
        case Jc.Worktree.merge(project_dir(socket.assigns.projects, t.project_id), wt) do
          :ok -> "🌳 merged #{wt.branch} → #{wt.base}"
          {:error, m} -> "🌳 merge failed: #{m}"
        end

      commit(update_thread(socket, cur, fn x -> %{x | blocks: x.blocks ++ [%{type: :marker, text: text}]} end))
    end
  end

  def handle_event("discard_wt", _p, socket) do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]
    wt = t && Map.get(t, :worktree)

    if wt == nil do
      {:noreply, socket}
    else
      Jc.Worktree.discard(project_dir(socket.assigns.projects, t.project_id), wt)
      stop_pids(t)
      marker = %{type: :marker, text: "🌳 discarded #{wt.branch}"}
      t = %{t | worktree: nil, agent: nil, run_pid: nil, running: false, blocks: t.blocks ++ [marker]}
      commit(assign(socket, threads: Map.put(socket.assigns.threads, cur, t)))
    end
  end

  def handle_event("approve", %{"decision" => d}, socket) do
    p = socket.assigns.pending_perm
    if p, do: send(p.pid, {:permission_response, p.ref, if(d == "allow", do: :allow, else: :deny)})
    {:noreply, assign(socket, pending_perm: nil)}
  end

  # click an advertised ACP slash command -> send it as "/name" (the agent runs it)
  def handle_event("send_command", %{"cmd" => name}, socket),
    do: handle_event("send", %{"message" => "/" <> name}, socket)

  # background probe (no prompt) to populate the / menu BEFORE the first message; the hook fires
  # this when the input mounts with no cached commands. No-op once commands are cached/persisted.
  def handle_event("probe_commands", _p, socket), do: {:noreply, probe_current_commands(socket)}

  # spawn a no-prompt ACP probe for the current thread's backend if its commands aren't cached yet.
  # Called on thread activation (select/new/switch) AND by the input hook, since the hook's updated()
  # only fires when data-commands changes (which it doesn't when switching between two empty backends).
  defp probe_current_commands(socket) do
    cur = socket.assigns.current
    t = cur && socket.assigns.threads[cur]

    if t do
      cached = Map.get(socket.assigns.acp_commands, t.backend)
      # push THIS thread's backend commands to the hook directly (don't rely on data-commands
      # re-rendering, which LiveView skips on a thread switch that doesn't touch @acp_commands)
      socket = push_event(socket, "acp_commands", %{commands: cached || []})

      if cached == nil do
        cd_to(thread_cwd(t, socket.assigns.projects))
        t = ensure_agent(t)
        if t.agent, do: :erlang.spawn(:jet_console, :run_to_tagged, [t.agent, :chat, [:jet_list_commands], self(), cur])
        assign(socket, threads: Map.put(socket.assigns.threads, cur, t))
      else
        socket
      end
    else
      socket
    end
  end

  # "!cmd" -> run a shell command in this thread's cwd (worktree/project) and show output inline,
  # without involving the agent. Quick one-offs; use the 🖥 terminal for long-running/interactive.
  def handle_event("send", %{"message" => "!" <> cmd}, socket) when cmd != "" do
    cur = socket.assigns.current
    t = cur && socket.assigns.threads[cur]

    if t do
      cwd = thread_cwd(t, socket.assigns.projects) || File.cwd!()

      {output, status} =
        try do
          System.cmd("sh", ["-c", cmd], cd: cwd, stderr_to_stdout: true)
        rescue
          e -> {Exception.message(e), 1}
        end

      blocks = t.blocks ++ [%{type: :user, text: "!" <> cmd}, %{type: :shell, text: output, status: status}]
      commit(update_thread(socket, cur, fn x -> %{x | blocks: blocks} end))
    else
      {:noreply, socket}
    end
  end

  def handle_event("send", %{"message" => msg}, socket) when is_binary(msg) and msg != "" do
    cur = socket.assigns.current
    t = socket.assigns.threads[cur]

    if t == nil or t.running do
      {:noreply, socket}
    else
      cd_to(thread_cwd(t, socket.assigns.projects))   # this thread's worktree (if isolated) or project folder
      t = ensure_agent(t)

      if t.agent == nil do
        {:noreply, socket}
      else
        {prompt, t} =
          if Map.get(t, :carry, false),
            do: {context_preamble(t.blocks) <> msg, %{t | carry: false}},
            else: {msg, t}

        Jc.TurnBuffer.start_turn(cur)   # route the turn's events through a buffer so a reload can reconnect
        run_pid = :erlang.spawn(:jet_console, :run_to_tagged, [t.agent, :chat, [prompt], Jc.TurnBuffer.target(), cur])
        title = if t.title == "New thread", do: String.slice(msg, 0, 32), else: t.title
        t = %{t | running: true, run_pid: run_pid, title: title, turn_usage: nil, blocks: t.blocks ++ [%{type: :user, text: msg}]}
        commit(assign(socket, threads: Map.put(socket.assigns.threads, cur, t), traces: Map.put(socket.assigns.traces, cur, [])))
      end
    end
  end

  def handle_event("send", _p, socket), do: {:noreply, socket}

  # --- agent-file editor events -------------------------------------------
  def handle_event("open_agents", _p, socket),
    do: {:noreply, assign(socket, editing: load_editing(List.first(AgentStore.files())), settings: nil, builder: nil)}

  def handle_event("close_agents", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  # the unified Agents panel (Builder / Backends / Files share one tabbed modal)
  def handle_event("close_agents_panel", _p, socket),
    do: {:noreply, assign(socket, editing: nil, settings: nil, builder: nil)}

  # the shared tab strip atop the Agents panel (each tab opens its section; opens are exclusive)
  defp agents_tabbar(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:.15rem;padding:.45rem .6rem;border-bottom:1px solid var(--bd);background:var(--panel);flex-shrink:0">
      <button type="button" phx-click="open_builder" style={agents_tab_style(@active == :builder)}>🤖 Builder</button>
      <button type="button" phx-click="open_settings" style={agents_tab_style(@active == :backends)}>🔌 Backends</button>
      <button type="button" phx-click="open_agents" style={agents_tab_style(@active == :files)}>✎ Agent files</button>
      <span style="margin-left:auto"></span>
      <button type="button" phx-click="close_agents_panel" title="Close" style="border:0;background:none;cursor:pointer;color:var(--mut);font-size:1.05rem;padding:.1rem .5rem">✕</button>
    </div>
    """
  end

  defp agents_tab_style(active) do
    base = "border:0;border-radius:.4rem .4rem 0 0;cursor:pointer;padding:.4rem .9rem;font-size:.85rem;"
    if active,
      do: base <> "background:var(--card);color:var(--tx);font-weight:600",
      else: base <> "background:none;color:var(--mut)"
  end

  def handle_event("edit_file", %{"file" => file}, socket),
    do: {:noreply, assign(socket, editing: load_editing(file))}

  def handle_event("save_file", %{"content" => content}, socket) do
    e = socket.assigns.editing
    AgentStore.write(e.file, content)

    case AgentStore.compile_load(e.file) do
      :ok ->
        cat = AgentStore.catalog()
        {:noreply, assign(socket, agents: cat, editing: %{e | content: content, error: nil, saved: "✓ Saved & hot-reloaded — #{length(cat)} agent(s) available"})}

      {:error, out} ->
        {:noreply, assign(socket, editing: %{e | content: content, error: out, saved: nil})}
    end
  end

  def handle_event("new_file", %{"name" => name}, socket) do
    name = String.replace(name, ~r/[^a-z0-9_]/, "")

    if name == "" do
      {:noreply, socket}
    else
      file = name <> ".jet"
      AgentStore.write(file, AgentStore.template(name))
      AgentStore.compile_load(file)
      {:noreply, assign(socket, agents: AgentStore.catalog(), editing: load_editing(file))}
    end
  end

  def handle_event("delete_file", %{"file" => file}, socket) do
    AgentStore.delete(file)
    {:noreply, assign(socket, agents: AgentStore.catalog(), editing: load_editing(List.first(AgentStore.files())))}
  end

  # --- project context viewer (CLAUDE.md/AGENTS.md/README.md + skills) ----
  def handle_event("open_context", _p, socket), do: {:noreply, assign(socket, context: ctx_open(socket))}
  def handle_event("close_context", _p, socket), do: {:noreply, assign(socket, context: nil)}

  def handle_event("ctx_item", %{"id" => id}, socket),
    do: {:noreply, assign(socket, context: ctx_load(%{socket.assigns.context | current: id}))}

  # --- file viewer/editor (browse + edit the project/worktree files) ------
  def handle_event("open_files", _p, socket) do
    dir = files_root(socket)
    {:noreply, assign(socket, files: files_at(dir, dir))}
  end

  def handle_event("close_files", _p, socket), do: {:noreply, assign(socket, files: nil)}

  # --- backend settings (local models / coding agent / Ollama URL) ----------
  def handle_event("open_settings", _p, socket),
    do: {:noreply, assign(socket, settings: settings_state(Jc.Settings.load()), editing: nil, builder: nil)}

  def handle_event("close_settings", _p, socket), do: {:noreply, assign(socket, settings: nil)}

  def handle_event("settings_change", params, socket) do
    s = socket.assigns.settings
    {:noreply, assign(socket, settings: %{s | form: merge_form(s.form, params), saved: nil})}
  end

  def handle_event("detect_ollama", _p, socket) do
    s = socket.assigns.settings

    {:noreply,
     assign(socket,
       settings: %{
         s
         | ollama: Jc.Settings.ollama_models(s.form["ollama_url"]),
           acp: Jc.Settings.acp_path(s.form["coding_drive"]),
           saved: nil
       }
     )}
  end

  def handle_event("save_settings", params, socket) do
    saved = Jc.Settings.save(params)
    s = settings_state(saved)
    {:noreply, assign(socket, settings: %{s | saved: "✓ Saved — new threads (or re-pick the agent) use these."})}
  end

  defp settings_state(saved) do
    form = Map.merge(Jc.Settings.defaults(), Map.take(saved, Jc.Settings.keys()))

    %{
      form: form,
      ollama: Jc.Settings.ollama_models(form["ollama_url"]),
      acp: Jc.Settings.acp_path(form["coding_drive"]),
      saved: nil
    }
  end

  defp merge_form(form, params), do: Map.merge(form, Map.take(params, Jc.Settings.keys()))

  # --- no-code agent builder ------------------------------------------------
  def handle_event("open_builder", _p, socket),
    do: {:noreply, assign(socket, builder: %{list: Jc.AgentBuilder.load(), form: nil, saved: nil, error: nil}, editing: nil, settings: nil)}

  def handle_event("close_builder", _p, socket), do: {:noreply, assign(socket, builder: nil)}

  def handle_event("builder_new", _p, socket),
    do: {:noreply, assign(socket, builder: %{socket.assigns.builder | form: new_agent_form(), saved: nil, error: nil})}

  def handle_event("builder_edit", %{"key" => key}, socket) do
    b = socket.assigns.builder
    cfg = Enum.find(b.list, &(&1["key"] == key)) || %{}
    {:noreply, assign(socket, builder: %{b | form: form_of_cfg(cfg), saved: nil, error: nil})}
  end

  def handle_event("builder_clone", %{"key" => key}, socket) do
    b = socket.assigns.builder
    src = Enum.find(b.list, &(&1["key"] == key)) || %{}
    cfg = Map.merge(src, %{"key" => "#{src["key"]}_copy", "label" => "#{src["label"] || src["key"]} (copy)"})
    {:noreply, assign(socket, builder: %{b | form: form_of_cfg(cfg), saved: nil, error: nil})}
  end

  def handle_event("builder_change", params, socket) do
    b = socket.assigns.builder
    {:noreply, assign(socket, builder: %{b | form: Map.merge(b.form || new_agent_form(), norm_agent_form(params)), saved: nil})}
  end

  def handle_event("builder_save", params, socket) do
    b = socket.assigns.builder
    form = Map.merge(b.form || new_agent_form(), norm_agent_form(params))

    case cfg_of_form(form) do
      {:ok, cfg} ->
        list = Jc.AgentBuilder.put(cfg)
        send(self(), :refresh_catalog)
        {:noreply, assign(socket, builder: %{list: list, form: form, saved: "✓ Saved + hot-loaded.", error: nil})}

      {:error, msg} ->
        {:noreply, assign(socket, builder: %{b | form: form, error: msg, saved: nil})}
    end
  end

  def handle_event("builder_delete", %{"key" => key}, socket) do
    list = Jc.AgentBuilder.delete(key)
    send(self(), :refresh_catalog)
    {:noreply, assign(socket, builder: %{socket.assigns.builder | list: list, form: nil, saved: "✓ Deleted.", error: nil})}
  end

  def handle_info(:refresh_catalog, socket), do: {:noreply, assign(socket, agents: AgentStore.catalog())}

  # a background `gh repo clone` finished: open the clone on success, else show gh's error
  def handle_info({:clone_done, _ref, dest, {_out, 0}}, socket), do: add_project(socket, dest)

  def handle_info({:clone_done, ref, _dest, {out, _code}}, socket),
    do: {:noreply, assign(socket, proj_error: "gh clone #{ref} failed: #{String.trim(String.slice(to_string(out), 0, 300))}")}

  defp new_agent_form do
    %{"key" => "", "label" => "", "type" => "simple", "backend" => "drives",
      "drives" => "claude-code-acp", "model" => "",
      "role" => "You are a helpful assistant.", "tool_fuel" => "12", "tools" => [],
      "runner" => "Goal", "via" => "Architect", "accept" => "", "max_rounds" => "3",
      "surface" => false, "members_text" => "", "rmodels_text" => "",
      "router" => "", "checker" => ""}
  end

  defp form_of_cfg(cfg) do
    new_agent_form()
    |> Map.merge(Map.take(cfg, ~w(key label type backend drives model role runner via accept router checker)))
    |> Map.put("tool_fuel", to_string(cfg["tool_fuel"] || "12"))
    |> Map.put("max_rounds", to_string(cfg["max_rounds"] || "3"))
    |> Map.put("surface", cfg["surface"] == true)
    |> Map.put("tools", cfg["tools"] || [])
    |> Map.put("members_text", members_to_text(cfg["members"] || []))
    |> Map.put("rmodels_text", rmodels_to_text(cfg["rmodels"] || []))
  end

  defp norm_agent_form(params) do
    params
    |> Map.put_new("tools", [])
    |> Map.update("surface", false, &(&1 in ["true", "on", true]))
  end

  defp cfg_of_form(form) do
    key = String.trim(form["key"] || "")

    cond do
      key == "" ->
        {:error, "Key is required."}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, key) ->
        {:error, "Key must be lowercase letters/digits/underscore, starting with a letter."}

      true ->
        {:ok,
         %{
           "key" => key, "label" => nonblank(form["label"]) || key, "type" => form["type"],
           "backend" => form["backend"], "model" => form["model"], "drives" => form["drives"],
           "role" => form["role"], "tool_fuel" => int_or(form["tool_fuel"], 12),
           "tools" => form["tools"] || [], "runner" => form["runner"], "via" => form["via"],
           "accept" => form["accept"], "max_rounds" => int_or(form["max_rounds"], 3),
           "surface" => form["surface"] == true,
           "members" => parse_members(form["members_text"]),
           "rmodels" => parse_rmodels(form["rmodels_text"]),
           "router" => form["router"], "checker" => form["checker"]
         }}
    end
  end

  defp members_to_text(list), do: Enum.map_join(list, "\n", fn m -> "#{m["name"]}: #{m["role"]}" end)

  defp parse_members(text) do
    (text || "")
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, i} ->
      case String.split(line, ":", parts: 2) do
        [name, role] -> %{"name" => String.trim(name), "role" => String.trim(role)}
        [role] -> %{"name" => "Member#{i}", "role" => String.trim(role)}
      end
    end)
  end

  defp rmodels_to_text(list),
    do: Enum.map_join(list, "\n", fn m -> [m["name"], m["tier"], m["lang"], m["good_at"]] |> Enum.map(&(&1 || "")) |> Enum.join(" | ") end)

  defp parse_rmodels(text) do
    (text || "")
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, tier, lang, good] = (String.split(line, "|") ++ ["", "", "", ""]) |> Enum.take(4) |> Enum.map(&String.trim/1)
      %{"name" => name, "tier" => tier, "lang" => lang, "good_at" => good}
    end)
    |> Enum.reject(&(&1["name"] == ""))
  end

  defp nonblank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp nonblank(_), do: nil
  defp int_or(v, _d) when is_integer(v), do: v
  defp int_or(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      _ -> d
    end
  end
  defp int_or(_, d), do: d

  defp inp,
    do: "width:100%;margin-top:.15rem;padding:.3rem .45rem;border:1px solid var(--bd2);border-radius:.3rem;background:var(--panel);color:var(--tx);font-size:.82rem;font-family:ui-monospace,monospace"

  def handle_event("files_cd", %{"dir" => d}, socket) do
    f = socket.assigns.files
    target = Path.expand(d)

    if f && String.starts_with?(target <> "/", f.root <> "/"),
      do: {:noreply, assign(socket, files: files_at(f.root, target))},
      else: {:noreply, socket}
  end

  def handle_event("file_open", %{"name" => name}, socket) do
    f = socket.assigns.files
    path = Path.join(f.dir, name)
    ext = String.downcase(Path.extname(name))
    size = case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end

    files =
      if size > 2_000_000 do
        # too big to load into the browser (e.g. erl_crash.dump, logs) -> don't read it
        %{f | file: path, content: "", ext: ext, kind: :toolarge, size: size, mode: :source, gen: f.gen + 1, saved: nil}
      else
        {content, kind} =
          case File.read(path) do
            {:ok, c} -> {c, file_kind(ext, c)}
            _ -> {"(could not read #{name})", :text}
          end

        mode = if ext in [".md", ".markdown", ".html", ".htm"] and kind == :text, do: :preview, else: :source
        %{f | file: path, content: content, ext: ext, kind: kind, size: size, mode: mode, gen: f.gen + 1, saved: nil}
      end

    {:noreply, assign(socket, files: files)}
  end

  # classify a file so we never render binary bytes as text (which crashes the render)
  defp file_kind(ext, content) do
    cond do
      ext in ~w(.png .jpg .jpeg .gif .svg .webp .ico .bmp .avif) -> :image
      not String.valid?(content) -> :binary
      true -> :text
    end
  end

  @image_mimes %{".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
                 ".gif" => "image/gif", ".svg" => "image/svg+xml", ".webp" => "image/webp",
                 ".ico" => "image/x-icon", ".bmp" => "image/bmp", ".avif" => "image/avif"}

  defp image_data_uri(ext, content),
    do: "data:" <> Map.get(@image_mimes, ext, "application/octet-stream") <> ";base64," <> Base.encode64(content)

  defp human_size(b) when b >= 1_000_000, do: "#{Float.round(b / 1_000_000, 1)} MB"
  defp human_size(b) when b >= 1_000, do: "#{div(b, 1000)} KB"
  defp human_size(b), do: "#{b} B"

  def handle_event("toggle_file_mode", _p, socket) do
    f = socket.assigns.files
    {:noreply, assign(socket, files: %{f | mode: if(f.mode == :preview, do: :source, else: :preview)})}
  end

  def handle_event("save_project_file", %{"content" => content}, socket) do
    f = socket.assigns.files

    msg =
      cond do
        f.file == nil -> nil
        File.write(f.file, content) == :ok -> "✓ saved #{Path.basename(f.file)}"
        true -> "save failed"
      end

    {:noreply, assign(socket, files: %{f | content: content, saved: msg})}
  end

  # --- in-console terminal (PTY-backed shell, opens in the thread's cwd) ---
  def handle_event("open_terminal", _p, socket) do
    cur = socket.assigns.current

    if cur && not Map.has_key?(socket.assigns.terminals, cur) do
      {:noreply, assign(socket, terminals: Map.put(socket.assigns.terminals, cur, %{}), dock_tab: :terminal)}
    else
      {:noreply, assign(socket, dock_tab: :terminal)}
    end
  end

  def handle_event("dock_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, dock_tab: String.to_existing_atom(tab))}

  def handle_event("close_dock", _p, socket) do
    case dock_active(socket.assigns) do
      :terminal -> handle_event("close_terminal", %{}, socket)
      :structure -> {:noreply, assign(socket, structure: nil)}
      _ -> {:noreply, socket}
    end
  end

  # agent-structure viz: probe the current agent for its composition (jet_describe), draw it as a
  # mermaid diagram in a docked panel. The probe runs nothing — it returns the static config.
  def handle_event("show_structure", _p, socket),
    do: {:noreply, assign(probe_structure(socket), dock_tab: :structure)}

  defp probe_structure(socket) do
    cur = socket.assigns.current
    t = cur && socket.assigns.threads[cur]

    if t do
      cd_to(thread_cwd(t, socket.assigns.projects))
      t = ensure_agent(t)
      if t.agent, do: :erlang.spawn(:jet_console, :run_to_tagged, [t.agent, :chat, [:jet_describe], self(), cur])
      assign(socket, structure: :loading, threads: Map.put(socket.assigns.threads, cur, t))
    else
      socket
    end
  end

  # re-probe the structure for the now-current thread, but only if the panel is already open
  defp maybe_reprobe_structure(socket) do
    if socket.assigns.structure, do: probe_structure(socket), else: socket
  end

  def handle_event("close_structure", _p, socket), do: {:noreply, assign(socket, structure: nil)}

  def handle_event("close_terminal", _p, socket) do
    cur = socket.assigns.current
    Jc.Terminals.close(cur)
    {:noreply, assign(socket, terminals: Map.delete(socket.assigns.terminals, cur))}
  end

  # the xterm hook (for thread `tid`) signals it's ready: spawn that thread's PTY in ITS OWN cwd
  # (worktree-aware) if it has none yet, else REPLAY the buffered scrollback into the fresh xterm.
  def handle_event("term_ready", %{"tid" => tid} = p, socket) do
    tid = String.to_integer(tid)

    if Map.has_key?(socket.assigns.terminals, tid) do
      t = socket.assigns.threads[tid]
      cwd = (t && thread_cwd(t, socket.assigns.projects)) || File.cwd!()
      cols = p["cols"] || 120
      rows = p["rows"] || 30
      buf = Jc.Terminals.ensure(tid, cwd, cols, rows)   # spawns the PTY (sized once) if new; returns scrollback
      {:noreply, push_event(socket, "term_output", %{d: buf})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("term_input", %{"d" => d, "tid" => tid}, socket) do
    Jc.Terminals.input(String.to_integer(tid), d)
    {:noreply, socket}
  end

  def handle_event("term_resize", %{"tid" => tid, "cols" => cols, "rows" => rows}, socket) do
    Jc.Terminals.resize(String.to_integer(tid), cols, rows)
    {:noreply, socket}
  end

  # the file tree's root: the current thread's worktree (if isolated) or its project folder.
  defp files_root(socket) do
    t = socket.assigns.current && socket.assigns.threads[socket.assigns.current]
    (t && thread_cwd(t, socket.assigns.projects)) || File.cwd!()
  end

  defp files_at(root, dir) do
    entries =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.map(fn n -> %{name: n, dir?: File.dir?(Path.join(dir, n))} end)
          |> Enum.sort_by(fn e -> {not e.dir?, String.downcase(e.name)} end)

        _ -> []
      end

    %{root: root, dir: dir, entries: entries, file: nil, content: "", ext: "", kind: :text, size: 0, mode: :source, gen: 0, saved: nil}
  end

  defp ctx_open(socket) do
    dir = project_dir(socket.assigns.projects, socket.assigns.current_project) || File.cwd!()
    cd_to(dir)
    files = for f <- ["AGENTS.md", "CLAUDE.md", "README.md"], File.exists?(Path.join(dir, f)), do: %{id: f, label: f, kind: :file, desc: ""}
    skills = for {name, desc} <- ctx_skills(), do: %{id: "skill:" <> name, label: name, kind: :skill, name: name, desc: desc}
    ctx = %{dir: dir, items: files ++ skills, current: nil, content: ""}

    case ctx.items do
      [first | _] -> ctx_load(%{ctx | current: first.id})
      [] -> ctx
    end
  end

  defp ctx_skills do
    try do
      :jet_skills.catalog([]) |> Enum.map(fn {id, desc} -> {to_s(id), to_s(desc)} end)
    rescue
      _ -> []
    end
  end

  defp ctx_load(ctx) do
    content =
      case Enum.find(ctx.items, &(&1.id == ctx.current)) do
        %{kind: :file, id: name} ->
          case File.read(Path.join(ctx.dir, name)) do
            {:ok, c} -> c
            _ -> ""
          end

        %{kind: :skill, name: name} ->
          cd_to(ctx.dir)
          try do
            to_s(:jet_skills.body([], name))
          rescue
            _ -> "(could not load skill)"
          end

        _ -> ""
      end

    %{ctx | content: content}
  end

  defp load_editing(nil), do: %{file: nil, content: "", error: nil, saved: nil, files: AgentStore.files()}

  defp load_editing(file) do
    content = case AgentStore.read(file) do
      {:ok, c} -> c
      _ -> ""
    end

    %{file: file, content: content, error: nil, saved: nil, files: AgentStore.files()}
  end

  # --- stream events ------------------------------------------------------
  @impl true
  def handle_info({:jet_event_tag, tid, {:permission, ref, pid, title, kind}}, socket) do
    socket = assign(socket, pending_perm: %{tid: tid, ref: ref, pid: pid, title: to_s(title), kind: to_s(kind)})
    {:noreply, maybe_notify(socket, tid, :permission)}
  end

  # ACP slash commands the agent advertises (available_commands_update). Stash them (not a block)
  # so the input can offer them; the agent runs `/name args` sent as a normal prompt.
  def handle_info({:jet_event_tag, tid, {:describe, desc}}, socket) do
    if tid == socket.assigns.current and socket.assigns.structure do
      {:noreply, assign(socket, structure: structure_mermaid(socket, desc))}
    else
      {:noreply, socket}
    end
  end

  # dynamic-trace span from a shape runner: upsert into this thread's live execution trace
  def handle_info({:jet_event_tag, tid, {:trace, span}}, socket) do
    list = upsert_trace(Map.get(socket.assigns.traces, tid, []), span)
    {:noreply, assign(socket, traces: Map.put(socket.assigns.traces, tid, list))}
  end

  # tool calls become trace leaves (nested under the running structure) -- so the run's STRUCTURE
  # and its tool ACTIVITY are one unified tree, not two disconnected lists.
  def handle_info({:jet_event_tag, tid, {:tool_call, info}}, socket) when is_map(info) do
    key = to_s(Map.get(info, :id) || Map.get(info, :title) || "tool")
    id = "tool:" <> key
    list = Map.get(socket.assigns.traces, tid, [])
    existing = Enum.find(list, &(&1.id == id))
    new_title = to_s(Map.get(info, :title))
    # claude-code-acp sends the readable title only on the FIRST event; later status updates carry an
    # empty title -> keep the label we already captured instead of blanking it.
    label =
      cond do
        new_title != "" -> "🔧 " <> new_title
        existing != nil -> existing.label
        true -> "🔧 " <> key
      end
    # fix the parent at creation; an explicit :parent (a Flow node relaying a child's tool) wins.
    parent = if existing, do: existing.parent, else: Map.get(info, :parent) || last_struct_id(list)
    span = %{id: id, parent: parent, label: label, status: to_s(Map.get(info, :status) || "running"), kind: :tool}
    {:noreply, assign(socket, traces: Map.put(socket.assigns.traces, tid, upsert_trace(list, span)))}
  end

  def handle_info({:jet_event_tag, tid, {:commands, cmds}}, socket) do
    case socket.assigns.threads[tid] do
      %{backend: backend} ->
        socket = assign(socket, acp_commands: Map.put(socket.assigns.acp_commands, backend, cmds))
        Jc.ThreadStore.put(socket.assigns)   # persist per-backend commands across reloads
        socket = if tid == socket.assigns.current, do: push_event(socket, "acp_commands", %{commands: cmds}), else: socket
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # a turn's token/cost aggregate ({:usage, scope: :turn} from jet_usage) -> remember it for
  # the reply badge and fold it into the thread's running total. Per-call events pass through.
  def handle_info({:jet_event_tag, tid, {:usage, u}}, socket) when is_map(u) do
    if Map.get(u, :scope) == :turn do
      {:noreply,
       update_thread(socket, tid, fn t ->
         %{t | turn_usage: u, usage_total: usage_add(Map.get(t, :usage_total) || %{}, u)}
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:jet_event_tag, tid, ev}, socket),
    do: {:noreply, update_thread(socket, tid, fn t -> %{t | blocks: apply_event(t.blocks, ev)} end)}

  def handle_info({:jet_done_tag, tid, _r}, socket) do
    socket =
      update_thread(socket, tid, fn t ->
        %{t | running: false, blocks: stamp_usage(t.blocks, Map.get(t, :turn_usage))}
      end)

    commit(maybe_notify(socket, tid, :finished))
  end

  # PTY output from the terminal's port -> the xterm hook.
  # PTY output relayed from Jc.Terminals: push to the xterm only when it's the thread on screen
  # (background terminals' output is buffered in Jc.Terminals and replayed on switch/reload).
  def handle_info({:term_out, tid, data}, socket) do
    if tid == socket.assigns.current,
      do: {:noreply, push_event(socket, "term_output", %{d: data})},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp update_thread(socket, tid, fun) do
    case socket.assigns.threads[tid] do
      nil -> socket
      t -> assign(socket, threads: Map.put(socket.assigns.threads, tid, fun.(t)))
    end
  end

  # kill a thread's running turn + its agent (so the work actually stops; re-spawns on next send)
  defp stop_pids(t) do
    if is_pid(t.run_pid), do: Process.exit(t.run_pid, :kill)
    if is_pid(t.agent), do: Process.exit(t.agent, :kill)
    :ok
  end

  defp first_thread_of(threads, pid) do
    case threads |> Map.values() |> Enum.filter(&(&1.project_id == pid)) |> Enum.sort_by(& &1.id) do
      [t | _] -> t.id
      [] -> nil
    end
  end

  # --- fold a structured agent event into a thread's blocks ---------------
  defp apply_event(blocks, {:text, t}) do
    case List.last(blocks) do
      %{type: :agent} = b -> List.replace_at(blocks, -1, %{b | text: b.text <> to_s(t)})
      _ -> blocks ++ [%{type: :agent, text: to_s(t)}]
    end
  end

  defp apply_event(blocks, {:thought, t}), do: blocks ++ [%{type: :thought, text: to_s(t)}]

  # streamed model thinking: accumulate consecutive deltas into ONE block (like {:text}), so a long
  # token-by-token thought doesn't become hundreds of near-empty 🤔 lines.
  defp apply_event(blocks, {:thinking, t}) do
    case List.last(blocks) do
      %{type: :thinking} = b -> List.replace_at(blocks, -1, %{b | text: b.text <> to_s(t)})
      _ -> blocks ++ [%{type: :thinking, text: to_s(t)}]
    end
  end

  defp apply_event(blocks, {:tool_call, info}) when is_map(info) do
    id = to_s(Map.get(info, :id) || Map.get(info, :title) || "tool")
    status = to_s(Map.get(info, :status) || "…")

    case Enum.find_index(blocks, &(&1.type == :tool and &1.id == id)) do
      nil -> blocks ++ [%{type: :tool, id: id, status: status}]
      idx -> List.replace_at(blocks, idx, %{type: :tool, id: id, status: status})
    end
  end

  defp apply_event(blocks, {:plan, items}) when is_list(items) do
    plan = %{type: :plan, items: Enum.map(items, &plan_item/1)}

    case Enum.find_index(blocks, &(&1.type == :plan)) do
      nil -> blocks ++ [plan]
      idx -> List.replace_at(blocks, idx, plan)
    end
  end

  defp apply_event(blocks, {:edit, path, old, new}),
    do: blocks ++ [%{type: :edit, path: to_s(path), old: to_s(old), new: to_s(new)}]

  defp apply_event(blocks, _), do: blocks

  defp plan_item(m) when is_map(m),
    do: %{title: to_s(Map.get(m, :content) || Map.get(m, :title) || Map.get(m, :id) || "·"), status: to_s(Map.get(m, :status) || "")}

  defp plan_item(other), do: %{title: to_s(other), status: ""}

  defp to_s(nil), do: ""
  defp to_s(x) when is_binary(x), do: x
  defp to_s(x) when is_list(x), do: List.to_string(x)
  defp to_s(x), do: inspect(x)

  # --- usage metering (tokens / cost / model time) --------------------------

  # attach the turn's usage to the reply it belongs to (the last agent block) so the
  # badge persists with the conversation (blocks survive ThreadStore restarts).
  defp stamp_usage(blocks, u) when is_map(u) do
    case List.last(blocks) do
      %{type: :agent} = b -> List.replace_at(blocks, -1, Map.put(b, :usage, u))
      _ -> blocks
    end
  end

  defp stamp_usage(blocks, _), do: blocks

  defp usage_add(total, u) do
    %{input: (total[:input] || 0) + num(u[:input]),
      output: (total[:output] || 0) + num(u[:output]),
      cost_usd: (total[:cost_usd] || 0) + num(u[:cost_usd]),
      duration_ms: (total[:duration_ms] || 0) + num(u[:duration_ms])}
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  # "↑1.2k ↓460 tok · $0.0421 · 12.4s" -- omits whatever the backend didn't report;
  # "" when nothing was metered (e.g. an ACP drive), so callers can hide the badge.
  defp usage_line(u) when is_map(u) do
    tok =
      case {num(u[:input]), num(u[:output])} do
        {0, 0} -> nil
        {i, o} -> "↑#{tok_s(i)} ↓#{tok_s(o)} tok"
      end

    cost = if num(u[:cost_usd]) > 0, do: "$#{:erlang.float_to_binary(num(u[:cost_usd]) * 1.0, decimals: 4)}"
    dur = if num(u[:duration_ms]) > 0, do: dur_s(num(u[:duration_ms]))
    [tok, cost, dur] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp usage_line(_), do: ""

  defp tok_s(n) when n >= 10_000, do: "#{div(n, 1000)}k"
  defp tok_s(n) when n >= 1_000, do: "#{Float.round(n / 1000, 1)}k"
  defp tok_s(n), do: "#{n}"

  defp dur_s(ms) when ms >= 60_000, do: "#{div(ms, 60_000)}m#{rem(div(ms, 1000), 60)}s"
  defp dur_s(ms) when ms >= 1_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp dur_s(ms), do: "#{ms}ms"

  # the recent conversation, inlined so a just-switched agent continues with context.
  defp context_preamble(blocks) do
    convo =
      blocks
      |> Enum.filter(&(&1.type in [:user, :agent]))
      |> Enum.take(-20)
      |> Enum.map_join("\n\n", fn
        %{type: :user, text: t} -> "User: " <> t
        %{type: :agent, text: t} -> "Assistant: " <> t
      end)

    if convo == "",
      do: "",
      else: "[Conversation so far in this thread, handled by a previous agent — continue it:]\n\n" <> convo <> "\n\n[Now respond to the next user message.]\n\n"
  end

  # render agent text as markdown, but colorize ```diff / ```patch blocks (green +, red -, blue @@).
  # which bottom-dock pane is showing: the picked tab if its pane is open, else whichever IS open
  defp dock_active(a) do
    term = Map.has_key?(a.terminals, a.current)
    cond do
      a.dock_tab == :terminal and term -> :terminal
      a.dock_tab == :structure and a.structure -> :structure
      term -> :terminal
      a.structure -> :structure
      true -> nil
    end
  end

  defp tab_style(true), do: "border:0;background:var(--card);border-radius:.3rem .3rem 0 0;cursor:pointer;padding:.25rem .7rem;font-size:.76rem;font-weight:600;color:var(--tx)"
  defp tab_style(false), do: "border:0;background:none;cursor:pointer;padding:.25rem .7rem;font-size:.76rem;color:var(--mut)"

  defp hide_unless(true), do: ""
  defp hide_unless(false), do: "display:none"

  # accumulate a shape runner's live trace spans, updating a span in place by its id
  defp upsert_trace(list, span) do
    entry = %{id: span.id, parent: Map.get(span, :parent, nil), label: to_s(span.label), status: to_s(span.status), kind: Map.get(span, :kind, :struct), ms: Map.get(span, :ms)}

    if Enum.any?(list, &(&1.id == entry.id)),
      do: Enum.map(list, fn e -> if e.id == entry.id, do: entry, else: e end),
      else: list ++ [entry]
  end

  # claude-code-acp's own tool calls (file/shell) parent to the most recent structural span
  defp last_struct_id(list) do
    case list |> Enum.reverse() |> Enum.find(&(&1.kind == :struct)) do
      nil -> nil
      e -> e.id
    end
  end

  # flatten the trace into DFS order with computed depth (the tree is built from parent links).
  # Anything whose parent is nil OR points outside this trace is treated as a root.
  defp trace_tree_order(list) do
    ids = MapSet.new(list, & &1.id)
    children = Enum.group_by(list, & &1.parent)
    roots = Enum.filter(list, fn e -> is_nil(e.parent) or not MapSet.member?(ids, e.parent) end)
    trace_dfs(roots, children, 0)
  end

  defp trace_dfs(nodes, children, depth) do
    Enum.flat_map(nodes, fn n -> [{n, depth} | trace_dfs(Map.get(children, n.id, []), children, depth + 1)] end)
  end

  # a span's elapsed time (:ms rides trace updates since jet_acp times each span);
  # "" for running spans, tool leaves, and traces persisted before the field existed.
  defp trace_ms(e) do
    case Map.get(e, :ms) do
      ms when is_integer(ms) and ms > 0 -> " (" <> dur_s(ms) <> ")"
      _ -> ""
    end
  end

  defp trace_icon("running"), do: "⏳"
  defp trace_icon("accepted"), do: "✅"
  defp trace_icon("rejected"), do: "↻"
  defp trace_icon("best-effort"), do: "⚠️"
  defp trace_icon("ok"), do: "✅"
  defp trace_icon("fail"), do: "❌"
  defp trace_icon("in_progress"), do: "⏳"
  defp trace_icon("pending"), do: "⏳"
  defp trace_icon("completed"), do: "✅"
  defp trace_icon("success"), do: "✅"
  defp trace_icon("failed"), do: "❌"
  defp trace_icon("error"), do: "❌"
  defp trace_icon(_), do: "•"

  # build a mermaid flowchart of the LIVE execution trace: each span is a node, edges link a span
  # to the most recent span one level shallower (depth-first emit order -> a correct tree).
  defp trace_mermaid([]), do: nil

  defp trace_mermaid(trace) do
    idx = trace |> Enum.with_index() |> Map.new(fn {e, i} -> {e.id, "t#{i}"} end)
    nodes = trace |> Enum.with_index() |> Enum.map(fn {e, i} -> ~s(  t#{i}["#{mq(trace_icon(e.status) <> " " <> trunc40(e.label) <> trace_ms(e))}"]) end)

    edges =
      Enum.flat_map(trace, fn e ->
        case e.parent && Map.get(idx, e.parent) do
          nil -> []
          p -> [~s(  #{p} --> #{Map.get(idx, e.id)})]
        end
      end)

    "```mermaid\nflowchart TD\n" <> Enum.join(nodes ++ edges, "\n") <> "\n```"
  end

  defp trunc40(s) do
    s = to_string(s)
    if String.length(s) > 40, do: String.slice(s, 0, 39) <> "…", else: s
  end

  # build a mermaid flowchart of an agent's composition from jet_agent::describe output
  defp structure_mermaid(socket, desc) do
    cur = socket.assigns.current
    t = cur && socket.assigns.threads[cur]
    name = (t && backend_label(t.backend, socket.assigns.agents)) || "agent"
    runner = desc[:runner] || :stub

    edges =
      [sn("D", "drives: ", desc[:drives], "  (ACP)"),
       sn("Mo", "model: ", desc[:model], ""),
       models_node(desc[:models], desc[:select]),
       sn("Vi", "via: ", desc[:via], ""),
       memory_node(desc[:memory])]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {id, label} -> ~s(  R --> #{id}["#{mq(label)}"]) end)

    body = [~s(  A["#{mq(name)}"] --> R["#{runner} runner"]) | edges] |> Enum.join("\n")
    "```mermaid\nflowchart TD\n" <> body <> "\n```"
  end

  defp sn(_id, _pre, v, _suf) when v in [nil, []], do: nil
  defp sn(id, pre, v, suf), do: {id, pre <> to_string(v) <> suf}

  defp models_node(ms, _sel) when ms in [nil, []], do: nil

  defp models_node(ms, sel) do
    list = ms |> Enum.map(&to_string/1) |> Enum.join(" → ")
    {"MS", "models: " <> list <> if(sel, do: "  (#{sel})", else: "")}
  end

  defp memory_node(m) when m in [nil, :session], do: nil
  defp memory_node(m), do: {"MEM", "memory: " <> to_string(m)}

  defp mq(s), do: s |> to_string() |> String.replace("\"", "'") |> String.replace("\n", " ")

  defp md(t) do
    ~r/(```(?:diff|patch)\r?\n.*?```)/s
    |> Regex.split(t, include_captures: true)
    |> Enum.map_join("", fn part ->
      case Regex.run(~r/```(?:diff|patch)\r?\n(.*?)```/s, part) do
        [_, body] -> diff_html(body)
        _ -> earmark(part)
      end
    end)
  end

  defp earmark(t) do
    case Earmark.as_html(t, compact_output: true) do
      {:ok, html, _} -> html
      _ -> t
    end
  end

  defp diff_html(body) do
    lines = body |> String.trim_trailing("\n") |> String.split("\n") |> Enum.map_join("", &diff_line/1)
    ~s[<pre style="background:var(--code);padding:.5rem .7rem;border-radius:.4rem;overflow-x:auto;font-size:.82rem;line-height:1.45;margin:.4rem 0"><code>] <> lines <> "</code></pre>"
  end

  defp diff_line(line) do
    esc = line |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

    cond do
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
        ~s[<span style="color:#2ea043;background:rgba(63,185,80,.14);display:block">#{esc}</span>]

      String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
        ~s[<span style="color:#cf222e;background:rgba(248,81,73,.13);display:block">#{esc}</span>]

      String.starts_with?(line, "@@") ->
        ~s[<span style="color:#8250df;display:block">#{esc}</span>]

      true ->
        ~s[<span style="display:block">#{esc}</span>]
    end
  end

  # a real line diff (Myers) of an edited file's old vs new text, colored + capped.
  defp edit_diff_html(old, new) do
    body =
      List.myers_difference(String.split(old, "\n"), String.split(new, "\n"))
      |> Enum.flat_map(fn {op, ls} -> Enum.map(ls, &{op, &1}) end)
      |> Enum.take(400)
      |> Enum.map_join("", &mdiff_line/1)

    ~s[<pre style="background:var(--code);padding:.5rem .7rem;overflow-x:auto;font-size:.8rem;line-height:1.45;margin:0"><code>] <> body <> "</code></pre>"
  end

  defp mdiff_line({op, l}) do
    esc = l |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

    case op do
      :del -> ~s[<span style="color:#cf222e;background:rgba(248,81,73,.13);display:block">- #{esc}</span>]
      :ins -> ~s[<span style="color:#2ea043;background:rgba(63,185,80,.14);display:block">+ #{esc}</span>]
      _ -> ~s[<span style="color:var(--mut);display:block">  #{esc}</span>]
    end
  end

  defp dot(s) do
    cond do
      String.contains?(s, "complet") -> "#22a06b"
      String.contains?(s, "fail") -> "#d04437"
      true -> "#d9a23b"
    end
  end

  defp plan_items(nil), do: []
  defp plan_items(p), do: p.items
  defp by_id(map), do: map |> Map.values() |> Enum.sort_by(& &1.id)
  defp threads_of(threads, pid), do: threads |> by_id() |> Enum.filter(&(&1.project_id == pid))

  # P1 — surface the (already-parallel) per-thread run state in the sidebar.
  defp running_count(threads), do: Enum.count(threads, fn {_id, t} -> t.running end)

  # :done once the agent has actually replied (an :agent block) — works for plain text replies too,
  # not just shape/tool runs that emit a trace.
  defp thread_status(t) do
    cond do
      t.running -> :running
      Enum.any?(t.blocks || [], &(&1.type == :agent)) -> :done
      true -> :idle
    end
  end

  defp status_dot_style(:running), do: "background:#d9a23b;animation:jc-pulse 1.2s ease-in-out infinite"
  defp status_dot_style(:done), do: "background:#22a06b"
  defp status_dot_style(_), do: "background:var(--bd2)"

  # P4: ping the user when a thread finishes or needs approval. The server always pushes; the Notify
  # hook decides to ping ONLY when the window is unfocused (you've left) — when you're here, the P1
  # status dots / P2 board already show it.
  defp maybe_notify(socket, tid, kind) do
    title =
      case socket.assigns.threads[tid] do
        %{title: t} -> t
        _ -> "Agent"
      end

    {label, body} =
      case kind do
        :finished -> {"✓ " <> title, "Finished"}
        :permission -> {"🔔 " <> title, "Needs your approval"}
        _ -> {title, to_string(kind)}
      end

    push_event(socket, "notify", %{title: label, body: body, sound: true})
  end
  defp done?(s), do: String.contains?(s, "complet")

  # --- view ----------------------------------------------------------------
  @impl true
  def render(assigns) do
    ~H"""
    <% cur = @current && @threads[@current] %>
    <% proj = @projects[@current_project] %>
    <% blocks = (cur && cur.blocks) || [] %>
    <% conv = Enum.filter(blocks, &(&1.type in [:user, :agent, :thought, :thinking, :marker, :edit, :shell])) %>
    <% tools = Enum.filter(blocks, &(&1.type == :tool)) %>
    <% plan = Enum.find(blocks, &(&1.type == :plan)) %>
    <div class={if @theme == :dark, do: "jc dark", else: "jc"} style="display:flex;height:100vh;font-family:ui-sans-serif,system-ui;color:var(--tx);background:var(--bg);font-size:14px">
    <style>
      .jc{--bg:#fbfbfa;--panel:#f3f3f1;--panel2:#fcfcfb;--card:#fff;--bd:#e5e5e3;--bd2:#d5d5d3;--tx:#1a1a1a;--mut:#888;--sel:#e2e8ef;--sel2:#dde6f0;--code:#f0f0ee;--warn-bg:#fff8e9;--err-bg:#fdf3f2;--err-bd:#f3c9c4;--err-tx:#b03020;--ok-bg:#eefaf2;--ok-bd:#bfe6cf;--ok-tx:#1a7f4b}
      .jc.dark{--bg:#1b1b1f;--panel:#242429;--panel2:#202024;--card:#2b2b31;--bd:#37373f;--bd2:#43434d;--tx:#e7e7ea;--mut:#9a9aa3;--sel:#33333c;--sel2:#2b3a4d;--code:#1f1f24;--warn-bg:#33301f;--err-bg:#3a2422;--err-bd:#5a3a36;--err-tx:#f0a59c;--ok-bg:#1e2e26;--ok-bd:#2e5a44;--ok-tx:#7fd6a6}
      .md > :first-child { margin-top: 0; } .md > :last-child { margin-bottom: 0; }
      .md p { margin: .4rem 0; }
      .md pre { background:var(--panel); padding:.6rem .8rem; border-radius:.4rem; overflow-x:auto; font-size:.85rem; }
      .md code { background:var(--code); padding:.05rem .3rem; border-radius:.25rem; font-size:.88em; font-family:ui-monospace,monospace; }
      .md pre code { background:none; padding:0; }
      .md ul, .md ol { margin:.4rem 0; padding-left:1.3rem; } .md li { margin:.15rem 0; }
      .md h1,.md h2,.md h3 { margin:.7rem 0 .3rem; line-height:1.3; } .md h1{font-size:1.3rem} .md h2{font-size:1.15rem} .md h3{font-size:1rem}
      .md blockquote { border-left:3px solid var(--bd); margin:.4rem 0; padding-left:.7rem; color:var(--mut); }
      .md a { color:#0b66c3; } .md table { border-collapse:collapse; } .md td,.md th{ border:1px solid var(--bd); padding:.2rem .5rem; }
      @keyframes jc-pulse { 0%,100% { opacity:1 } 50% { opacity:.25 } }
    </style>
    <div id="notify" phx-hook="Notify" style="display:none"></div>
      <aside style="width:15rem;flex-shrink:0;border-right:1px solid var(--bd);background:var(--panel);display:flex;flex-direction:column">
        <div style="padding:.7rem .8rem;font-weight:600;border-bottom:1px solid var(--bd);display:flex;flex-direction:column;align-items:flex-start;gap:.5rem">
          <span>⚡ Jet Console</span>
          <span style="display:flex;gap:.55rem;flex-wrap:wrap">
            <button phx-click="toggle_theme" title="Toggle dark mode" style="border:0;background:none;cursor:pointer;font-size:1rem"><%= if @theme == :dark, do: "☀️", else: "🌙" %></button>
            <button phx-click="open_files" title="Browse + edit project files" style="border:0;background:none;cursor:pointer;font-size:1rem">📁</button>
            <button phx-click="open_terminal" title="Open a terminal in this thread's folder" style="border:0;background:none;cursor:pointer;font-size:1rem">🖥</button>
            <button phx-click="show_structure" title="Visualize this agent's composition" style="border:0;background:none;cursor:pointer;font-size:1rem">🧬</button>
            <button phx-click="open_context" title="Project context (CLAUDE.md/AGENTS.md + skills)" style="border:0;background:none;cursor:pointer;font-size:1rem">📖</button>
            <button phx-click="open_builder" title="Agents — builder · backend settings · agent files" style="border:0;background:none;cursor:pointer;font-size:1rem">🤖</button>
            <button phx-click="toggle_board" title="Agents board: see all threads running in parallel" style="border:0;background:none;cursor:pointer;font-size:1rem">▦</button>
          </span>
        </div>
        <div style="padding:.4rem .55rem;font-size:.72rem;color:var(--mut);text-transform:uppercase;letter-spacing:.04em">Projects</div>
        <div style="padding:0 .25rem">
          <div :for={p <- by_id(@projects)} style="display:flex;align-items:stretch;gap:.1rem">
            <button phx-click="select_project" phx-value-id={p.id}
              style={"flex:1;min-width:0;text-align:left;border:0;border-radius:.4rem;padding:.3rem .55rem;cursor:pointer;background:#{if p.id == @current_project, do: "var(--sel2)", else: "transparent"}"}>
              📁 <%= p.name %>
              <div style="font-size:.66rem;color:var(--mut);font-family:ui-monospace,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= p.dir %></div></button>
            <button phx-click="remove_project" phx-value-id={p.id}
              data-confirm={"Remove project #{p.name} from the list? (its threads close; the folder on disk is kept)"}
              title="Remove from list (keeps the folder)"
              style="flex:none;border:0;background:transparent;color:var(--mut);cursor:pointer;padding:0 .4rem;border-radius:.4rem;font-size:.8rem">✕</button>
          </div>
          <form phx-submit="new_project" style="display:flex;gap:.25rem;padding:.25rem .3rem">
            <input name="dir" placeholder="path, or owner/repo to clone" autocomplete="off" style="flex:1;min-width:0;padding:.25rem;border:1px solid var(--bd2);border-radius:.3rem;font-size:.76rem"/>
            <button type="submit" title="Open folder as a project" style="padding:.25rem .45rem;border:1px solid var(--bd2);border-radius:.3rem;background:var(--card);cursor:pointer">+</button>
          </form>
          <div :if={@proj_error} style="color:#d04437;font-size:.7rem;padding:0 .35rem"><%= @proj_error %></div>
        </div>
        <div style="padding:.4rem .55rem;font-size:.72rem;color:var(--mut);text-transform:uppercase;letter-spacing:.04em;border-top:1px solid var(--bd);margin-top:.3rem">Threads<span :if={running_count(@threads) > 0} style="color:#d9a23b;text-transform:none;letter-spacing:0"> · <%= running_count(@threads) %> running</span></div>
        <div style="flex:1;overflow-y:auto;padding:0 .25rem">
          <div :for={t <- threads_of(@threads, @current_project)} style="display:flex;align-items:center;gap:.1rem;margin:.1rem 0">
            <%= if @renaming == t.id do %>
              <form phx-submit="rename_thread" phx-value-id={t.id} style="flex:1;display:flex">
                <input name="title" value={t.title} autocomplete="off" autofocus
                  style="flex:1;min-width:0;padding:.3rem .4rem;border:1px solid #0b66c3;border-radius:.4rem;font-size:.85rem" />
              </form>
            <% else %>
              <button phx-click="select" phx-value-id={t.id}
                style={"flex:1;min-width:0;text-align:left;border:0;border-radius:.4rem;padding:.4rem .55rem;cursor:pointer;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;background:#{if t.id == @current, do: "var(--sel)", else: "transparent"}"}>
<span title={to_string(thread_status(t))} style={"display:inline-block;width:.5rem;height:.5rem;border-radius:50%;margin-right:.45rem;vertical-align:middle;flex-shrink:0;#{status_dot_style(thread_status(t))}"}></span><%= t.title %></button>
              <button phx-click="rename_start" phx-value-id={t.id} title="Rename" style="border:0;background:none;cursor:pointer;color:var(--mut);padding:.1rem .2rem">✎</button>
              <button phx-click="del_thread" phx-value-id={t.id} data-confirm="Delete this thread?" title="Delete" style="border:0;background:none;cursor:pointer;color:#c66;padding:.1rem .25rem">×</button>
            <% end %>
          </div>
        </div>
        <form phx-change="set_backend" style="padding:.4rem .5rem 0">
          <select name="backend" style="width:100%;padding:.3rem;border:1px solid var(--bd2);border-radius:.4rem;background:var(--card)">
            <option :for={{m, k, label} <- @agents} value={"#{m}:#{k}"} selected={@new_backend == "#{m}:#{k}"}><%= label %></option>
          </select>
        </form>
        <button phx-click="new_thread" style="margin:.5rem;padding:.45rem;border:1px solid var(--bd2);border-radius:.4rem;background:var(--card);cursor:pointer">+ New thread</button>
      </aside>

      <main style="flex:1;display:flex;flex-direction:column;min-width:0">
        <header style="padding:.6rem 1rem;border-bottom:1px solid var(--bd);font-weight:600;display:flex;justify-content:space-between">
          <span><%= (cur && cur.title) || "No thread" %></span>
          <span style="font-weight:400;color:var(--mut);font-size:.78rem;display:flex;align-items:center;gap:.4rem">
            <form :if={cur} phx-change="switch_backend" style="margin:0">
              <select name="backend" title="Switch this thread's agent (carries the conversation)" style="font-size:.78rem;padding:.1rem .3rem;border:1px solid var(--bd);border-radius:.3rem;background:var(--card);color:var(--tx)">
                <option :for={{m, k, label} <- @agents} value={"#{m}:#{k}"} selected={cur.backend == "#{m}:#{k}"}><%= label %></option>
              </select>
            </form>
            <span>· 📁 <%= proj && proj.dir %></span>
            <span :if={cur && usage_line(Map.get(cur, :usage_total) || %{}) != ""} title="thread total: tokens in/out · cost · model time">· Σ <%= usage_line(Map.get(cur, :usage_total)) %></span>
            <%= if cur do %>
              <% wt = Map.get(cur, :worktree) %>
              <%= if wt do %>
                <span title={"isolated worktree: #{wt.path}"} style="color:#2ea043">· 🌳 <%= wt.branch %></span>
                <button phx-click="merge_wt" data-confirm={"Merge #{wt.branch} into #{wt.base}?"} title="Commit the worktree's changes + merge into the base branch" style="border:1px solid var(--bd);border-radius:.3rem;background:var(--card);color:var(--tx);cursor:pointer;font-size:.74rem;padding:.05rem .4rem">Merge</button>
                <button phx-click="discard_wt" data-confirm="Discard this worktree and its branch?" title="Remove the worktree + delete its branch (drops the changes)" style="border:1px solid var(--bd);border-radius:.3rem;background:var(--card);color:#c66;cursor:pointer;font-size:.74rem;padding:.05rem .4rem">Discard</button>
              <% else %>
                <button phx-click="isolate" title="Isolate this thread in its own git worktree + branch" style="border:1px solid var(--bd);border-radius:.3rem;background:var(--card);color:var(--tx);cursor:pointer;font-size:.74rem;padding:.05rem .4rem">🌳 Isolate</button>
              <% end %>
            <% end %>
          </span>
        </header>
        <div id="thread" phx-hook="Rich" style="flex:1;overflow-y:auto;padding:1rem 1.2rem;display:flex;flex-direction:column;gap:.55rem">
          <div :for={b <- conv}>
            <%= case b.type do %>
              <% :user -> %>
                <div style="align-self:flex-end;background:#0b66c3;color:#fff;padding:.45rem .7rem;border-radius:.8rem;max-width:80%;white-space:pre-wrap"><%= b.text %></div>
              <% :agent -> %>
                <div class="md" style="line-height:1.5"><%= raw(md(b.text)) %></div>
                <div :if={usage_line(Map.get(b, :usage)) != ""} title="this reply: tokens in/out · cost · model time" style="color:var(--mut);font-size:.72rem;margin-top:.15rem"><%= usage_line(Map.get(b, :usage)) %></div>
              <% :thought -> %>
                <div style="color:var(--mut);font-style:italic;font-size:.88rem">🤔 <%= b.text %></div>
              <% :thinking -> %>
                <div style="color:var(--mut);font-style:italic;font-size:.82rem;white-space:pre-wrap;opacity:.75">🤔 <%= b.text %></div>
              <% :marker -> %>
                <div style="text-align:center;color:var(--mut);font-size:.78rem;margin:.3rem 0"><%= b.text %></div>
              <% :edit -> %>
                <div style="border:1px solid var(--bd);border-radius:.5rem;margin:.2rem 0;overflow:hidden">
                  <div style="background:var(--panel);padding:.3rem .6rem;font-family:ui-monospace,monospace;font-size:.8rem">📝 <%= b.path %></div>
                  <%= raw(edit_diff_html(b.old, b.new)) %>
                </div>
              <% :shell -> %>
                <div style="border:1px solid var(--bd);border-radius:.5rem;margin:.2rem 0;overflow:hidden">
                  <div style={"background:var(--panel);padding:.25rem .6rem;font-family:ui-monospace,monospace;font-size:.76rem;color:" <> if(b.status == 0, do: "var(--mut)", else: "#d04437")}>🖥 shell · exit <%= b.status %></div>
                  <pre style="margin:0;padding:.5rem .6rem;max-height:18rem;overflow:auto;white-space:pre-wrap;font-family:ui-monospace,monospace;font-size:.8rem"><%= if b.text == "", do: "(no output)", else: b.text %></pre>
                </div>
            <% end %>
          </div>
          <div :if={cur && cur.running} style="color:var(--mut);font-size:.85rem;display:flex;align-items:center;gap:.5rem">· working… <button phx-click="stop" style="border:1px solid var(--bd2);border-radius:.3rem;background:var(--card);cursor:pointer;font-size:.78rem;padding:.1rem .5rem">Stop</button></div>
          <div :if={cur == nil} style="color:var(--mut);margin:auto">No thread — click “+ New thread”.</div>
        </div>
        <div :if={@pending_perm} style="margin:.5rem 1rem;padding:.6rem .8rem;border:1px solid #d9a23b;background:var(--warn-bg);border-radius:.5rem">
          <div style="font-size:.85rem;margin-bottom:.45rem">🔐 Permission requested: <strong><%= @pending_perm.kind %></strong> <%= @pending_perm.title %></div>
          <div style="display:flex;gap:.5rem">
            <button phx-click="approve" phx-value-decision="allow" style="padding:.3rem .9rem;border:0;border-radius:.4rem;background:#22a06b;color:#fff;cursor:pointer">Allow</button>
            <button phx-click="approve" phx-value-decision="deny" style="padding:.3rem .9rem;border:0;border-radius:.4rem;background:#d04437;color:#fff;cursor:pointer">Deny</button>
          </div>
        </div>
        <%!-- the message input hugs the conversation; the terminal/structure dock sits BELOW it --%>
        <form :if={cur} phx-submit="send" style="display:flex;gap:.5rem;align-items:flex-end;padding:.6rem 1rem;border-top:1px solid var(--bd)">
          <textarea name="message" id="agent-msg" phx-hook="SlashMenu" data-commands={Jason.encode!(Map.get(@acp_commands, cur[:backend], []))} placeholder="Ask the agent…  (type / for commands · Shift+Enter for newline)" autocomplete="off" rows="1" style="flex:1;box-sizing:border-box;padding:.5rem .7rem;border:1px solid var(--bd2);border-radius:.5rem;resize:none;font-family:inherit;font-size:inherit;line-height:1.4;max-height:160px;overflow-y:auto"></textarea>
          <button type="submit" disabled={cur && cur.running} style="padding:.5rem 1rem;border:0;border-radius:.5rem;background:#0b66c3;color:#fff">Send</button>
        </form>
        <%!-- bottom dock: resizable (drag the top edge), tabbed when terminal + structure both open --%>
        <div :if={Map.has_key?(@terminals, @current) || @structure} id="dock" phx-hook="DockResize" style="flex-shrink:0;display:flex;flex-direction:column;border-top:1px solid var(--bd2);height:var(--dock-h,20rem);min-height:120px">
          <div class="dock-resize" style="height:6px;flex-shrink:0;cursor:ns-resize;background:var(--bd2)"></div>
          <% active = dock_active(assigns) %>
          <div style="display:flex;align-items:flex-end;gap:.15rem;padding:.1rem .5rem 0;background:var(--panel);flex-shrink:0;border-bottom:1px solid var(--bd)">
            <button :if={Map.has_key?(@terminals, @current)} phx-click="dock_tab" phx-value-tab="terminal" style={tab_style(active == :terminal)}>🖥 terminal<%= if cur, do: " — " <> Path.basename(thread_cwd(cur, @projects)) %></button>
            <button :if={@structure} phx-click="dock_tab" phx-value-tab="structure" style={tab_style(active == :structure)}>🧬 structure</button>
            <span style="margin-left:auto"></span>
            <button phx-click="close_dock" title="Close" style="border:0;background:none;color:var(--mut);cursor:pointer;font-size:.9rem;padding:.1rem .4rem">✕</button>
          </div>
          <div style="flex:1;min-height:0;position:relative">
            <div :if={Map.has_key?(@terminals, @current)} style={"position:absolute;inset:0;background:#1b1b1f;" <> hide_unless(active == :terminal)}>
              <div id={"term-#{@current}"} phx-hook="Terminal" data-tid={@current} phx-update="ignore" style="width:100%;height:100%;padding:.3rem .4rem"></div>
            </div>
            <div :if={@structure} style={"position:absolute;inset:0;overflow:auto;padding:.6rem;background:var(--panel2);" <> hide_unless(active == :structure)}>
              <%= if @structure == :loading do %>
                <span style="color:var(--mut);font-size:.85rem">probing agent…</span>
              <% else %>
                <div id={"sv-" <> Integer.to_string(:erlang.phash2(@structure))} phx-hook="Rich" phx-update="ignore" class="md"><%= raw(md(@structure)) %></div>
              <% end %>
              <%= if Map.get(@traces, @current, []) != [] do %>
                <div style="margin-top:.7rem;font-size:.7rem;color:var(--mut);text-transform:uppercase;letter-spacing:.04em">This run</div>
                <div id={"tr-" <> Integer.to_string(:erlang.phash2(Map.get(@traces, @current, [])))} phx-hook="Rich" phx-update="ignore" class="md"><%= raw(md(trace_mermaid(Map.get(@traces, @current, [])))) %></div>
              <% end %>
            </div>
          </div>
        </div>
      </main>

      <aside :if={cur} id="aside" phx-hook="AsideResize" style="width:var(--aside-w,17rem);flex-shrink:0;border-left:1px solid var(--bd);background:var(--panel2);position:relative;display:flex">
        <div class="aside-resize" style="position:absolute;left:0;top:0;bottom:0;width:6px;cursor:ew-resize;z-index:1"></div>
        <div style="flex:1;min-width:0;overflow-y:auto;padding:.7rem .8rem">
        <div style="font-size:.72rem;color:var(--mut);text-transform:uppercase;letter-spacing:.04em;margin-bottom:.3rem">Plan</div>
        <div :if={plan == nil} style="color:var(--mut);font-size:.85rem">—</div>
        <div :for={it <- plan_items(plan)} style="font-size:.88rem;margin:.15rem 0;font-family:ui-monospace,monospace">
          <%= if done?(it.status), do: "☑", else: "☐" %> <%= it.title %></div>
        <div style="font-size:.72rem;color:var(--mut);text-transform:uppercase;letter-spacing:.04em;margin:.8rem 0 .3rem">Run <span style="text-transform:none;font-size:.68rem">(structure + tools · 🧬 for graph)</span></div>
        <div :if={Map.get(@traces, @current, []) == []} style="color:var(--mut);font-size:.85rem">—</div>
        <div :for={{e, d} <- trace_tree_order(Map.get(@traces, @current, []))} style={"font-size:.8rem;font-family:ui-monospace,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:.08rem 0;padding-left:#{d * 0.8}rem"}><%= trace_icon(e.status) %> <%= e.label %><span style="color:var(--mut)"><%= trace_ms(e) %></span></div>
        </div>
      </aside>

      <%!-- agent-file editor overlay --%>
      <div :if={@editing} style="position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;z-index:10">
        <div style="background:var(--card);width:min(58rem,95vw);height:88vh;border-radius:.6rem;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3)">
          <.agents_tabbar active={:files} />
          <div style="flex:1;display:flex;overflow:hidden;min-height:0">
          <div style="width:13rem;flex-shrink:0;border-right:1px solid var(--bd);background:var(--panel);display:flex;flex-direction:column">
            <div style="padding:.6rem;font-weight:600;border-bottom:1px solid var(--bd)">Files</div>
            <div style="flex:1;overflow-y:auto;padding:.2rem">
              <button :for={f <- @editing.files} phx-click="edit_file" phx-value-file={f}
                style={"display:block;width:100%;text-align:left;border:0;border-radius:.3rem;padding:.35rem .5rem;cursor:pointer;font-family:ui-monospace,monospace;font-size:.82rem;background:#{if f == @editing.file, do: "var(--sel)", else: "transparent"}"}><%= f %></button>
            </div>
            <form phx-submit="new_file" style="padding:.4rem;display:flex;gap:.25rem;border-top:1px solid var(--bd)">
              <input name="name" placeholder="new_name" autocomplete="off" style="flex:1;min-width:0;padding:.3rem;border:1px solid var(--bd2);border-radius:.3rem;font-size:.8rem"/>
              <button type="submit" style="padding:.3rem .5rem;border:1px solid var(--bd2);border-radius:.3rem;background:var(--card);cursor:pointer">+</button>
            </form>
          </div>
          <div style="flex:1;display:flex;flex-direction:column;padding:.7rem;min-width:0">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.4rem">
              <strong style="font-family:ui-monospace,monospace"><%= @editing.file || "(no agent files)" %></strong>
              <div style="display:flex;gap:.6rem">
                <button :if={@editing.file} phx-click="delete_file" phx-value-file={@editing.file} data-confirm="Delete this agent file?" style="color:#d04437;border:0;background:none;cursor:pointer">Delete</button>
                <button phx-click="close_agents" style="border:0;background:none;cursor:pointer">Close ✕</button>
              </div>
            </div>
            <form :if={@editing.file} phx-submit="save_file" style="flex:1;display:flex;flex-direction:column;gap:.4rem;min-height:0">
              <textarea name="content" spellcheck="false" style="flex:1;font-family:ui-monospace,monospace;font-size:.82rem;line-height:1.45;padding:.5rem;border:1px solid var(--bd2);border-radius:.4rem;resize:none;white-space:pre"><%= @editing.content %></textarea>
              <div :if={@editing.error} style="color:var(--err-tx);background:var(--err-bg);border:1px solid var(--err-bd);border-radius:.4rem;padding:.4rem .6rem;font-family:ui-monospace,monospace;font-size:.78rem;white-space:pre-wrap;max-height:7rem;overflow:auto"><%= @editing.error %></div>
              <div :if={@editing.saved} style="color:var(--ok-tx);background:var(--ok-bg);border:1px solid var(--ok-bd);border-radius:.4rem;padding:.4rem .6rem;font-size:.82rem"><%= @editing.saved %></div>
              <button type="submit" style="align-self:flex-start;padding:.45rem 1rem;border:0;border-radius:.4rem;background:#0b66c3;color:#fff;cursor:pointer">Save &amp; hot-reload</button>
            </form>
          </div>
          </div>
        </div>
      </div>

      <%!-- project context overlay: CLAUDE.md/AGENTS.md/README.md + discovered skills --%>
      <div :if={@context} style="position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;z-index:10">
        <div style="background:var(--card);width:82%;height:82%;border-radius:.6rem;display:flex;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3)">
          <div style="width:15rem;flex-shrink:0;border-right:1px solid var(--bd);background:var(--panel);display:flex;flex-direction:column">
            <div style="padding:.6rem;font-weight:600;border-bottom:1px solid var(--bd)">Project context</div>
            <div style="flex:1;overflow-y:auto;padding:.2rem">
              <button :for={it <- @context.items} phx-click="ctx_item" phx-value-id={it.id}
                style={"display:block;width:100%;text-align:left;border:0;border-radius:.3rem;padding:.35rem .5rem;margin:.05rem 0;cursor:pointer;font-size:.85rem;background:#{if it.id == @context.current, do: "var(--sel)", else: "transparent"}"}>
                <%= if it.kind == :skill, do: "🧩 ", else: "📄 " %><%= it.label %>
                <div :if={it.kind == :skill and it.desc != ""} style="font-size:.7rem;color:var(--mut);white-space:normal;line-height:1.3"><%= it.desc %></div>
              </button>
              <div :if={@context.items == []} style="padding:.5rem;color:var(--mut);font-size:.82rem">No CLAUDE.md / AGENTS.md or skills found in this project.</div>
            </div>
          </div>
          <div style="flex:1;display:flex;flex-direction:column;padding:.7rem 1rem;min-width:0">
            <div style="display:flex;justify-content:flex-end;margin-bottom:.3rem">
              <button phx-click="close_context" style="border:0;background:none;cursor:pointer">Close ✕</button>
            </div>
            <div class="md" id="ctx-md" phx-hook="Rich" style="flex:1;overflow-y:auto;line-height:1.5"><%= raw(md(@context.content)) %></div>
          </div>
        </div>
      </div>

      <%!-- file viewer/editor overlay: file tree + CodeMirror (textarea-fallback) editor --%>
      <div :if={@files} style="position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;z-index:10">
        <div style="background:var(--card);width:88%;height:88%;border-radius:.6rem;display:flex;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3)">
          <div style="width:16rem;flex-shrink:0;border-right:1px solid var(--bd);background:var(--panel);display:flex;flex-direction:column">
            <div style="padding:.5rem .6rem;font-weight:600;border-bottom:1px solid var(--bd);font-size:.82rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={@files.dir}>📁 /<%= Path.relative_to(@files.dir, @files.root) %></div>
            <div style="flex:1;overflow-y:auto;padding:.2rem">
              <button :if={@files.dir != @files.root} phx-click="files_cd" phx-value-dir={Path.dirname(@files.dir)} style="display:block;width:100%;text-align:left;border:0;background:none;cursor:pointer;padding:.3rem .5rem;font-family:ui-monospace,monospace;font-size:.82rem;color:var(--mut)">📁 ..</button>
              <%= for e <- @files.entries do %>
                <button :if={e.dir?} phx-click="files_cd" phx-value-dir={Path.join(@files.dir, e.name)} style="display:block;width:100%;text-align:left;border:0;background:none;cursor:pointer;padding:.3rem .5rem;font-family:ui-monospace,monospace;font-size:.82rem">📁 <%= e.name %></button>
                <button :if={not e.dir?} phx-click="file_open" phx-value-name={e.name} style={"display:block;width:100%;text-align:left;border:0;border-radius:.3rem;cursor:pointer;padding:.3rem .5rem;font-family:ui-monospace,monospace;font-size:.82rem;background:#{if @files.file == Path.join(@files.dir, e.name), do: "var(--sel)", else: "transparent"}"}>📄 <%= e.name %></button>
              <% end %>
            </div>
          </div>
          <div style="flex:1;display:flex;flex-direction:column;padding:.7rem;min-width:0">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.4rem">
              <strong style="font-family:ui-monospace,monospace;font-size:.84rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= (@files.file && Path.relative_to(@files.file, @files.root)) || "(select a file)" %></strong>
              <div style="display:flex;gap:.7rem;align-items:center">
                <span :if={@files.saved} style="color:var(--ok-tx);font-size:.8rem"><%= @files.saved %></span>
                <button :if={@files.file && @files.ext in [".md", ".markdown", ".html", ".htm"]} phx-click="toggle_file_mode" title="Toggle rendered preview / source" style="border:1px solid var(--bd);border-radius:.3rem;background:var(--card);color:var(--tx);cursor:pointer;font-size:.76rem;padding:.1rem .5rem"><%= if @files.mode == :preview, do: "✎ Source", else: "👁 Preview" %></button>
                <button phx-click="close_files" style="border:0;background:none;cursor:pointer">Close ✕</button>
              </div>
            </div>
            <%= cond do %>
              <% @files.file == nil -> %>
                <div style="flex:1;display:flex;align-items:center;justify-content:center;color:var(--mut)">Select a file from the tree to view or edit.</div>
              <% @files.kind == :image -> %>
                <div style="flex:1;overflow:auto;display:flex;align-items:center;justify-content:center;background:var(--panel);border-radius:.4rem">
                  <img src={image_data_uri(@files.ext, @files.content)} style="max-width:100%;max-height:100%;object-fit:contain" />
                </div>
              <% @files.kind == :binary -> %>
                <div style="flex:1;display:flex;align-items:center;justify-content:center;color:var(--mut);font-size:.9rem">Binary file — <%= human_size(@files.size) %> (can't display as text)</div>
              <% @files.kind == :toolarge -> %>
                <div style="flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;color:var(--mut);font-size:.9rem;gap:.4rem;text-align:center">
                  <div>📦 File too large to display — <%= human_size(@files.size) %></div>
                  <div style="font-size:.78rem">Open it from the 🖥 terminal instead (e.g. <code style="background:var(--code);padding:.05rem .3rem;border-radius:.25rem">less <%= @files.file && Path.basename(@files.file) %></code>)</div>
                </div>
              <% @files.mode == :preview and @files.ext in [".html", ".htm"] -> %>
                <iframe id={"filehtml-#{@files.gen}"} sandbox="" referrerpolicy="no-referrer" srcdoc={@files.content} style="flex:1;width:100%;border:1px solid var(--bd2);border-radius:.4rem;background:#fff"></iframe>
              <% @files.mode == :preview -> %>
                <div class="md" id={"filemd-#{@files.gen}"} phx-hook="Rich" style="flex:1;overflow-y:auto;line-height:1.55;padding:.2rem .5rem"><%= raw(md(@files.content)) %></div>
              <% true -> %>
                <form phx-submit="save_project_file" style="flex:1;display:flex;flex-direction:column;gap:.4rem;min-height:0">
                  <div style="flex:1;min-height:0;border:1px solid var(--bd2);border-radius:.4rem;overflow:hidden">
                    <textarea id={"cm-#{@files.gen}"} name="content" phx-hook="CodeEditor" phx-update="ignore" data-ext={@files.ext} data-dark={to_string(@theme == :dark)} spellcheck="false" style="width:100%;height:100%;font-family:ui-monospace,monospace;font-size:.82rem;border:0;padding:.5rem;resize:none;white-space:pre;background:var(--card);color:var(--tx)"><%= @files.content %></textarea>
                  </div>
                  <button type="submit" style="align-self:flex-start;padding:.45rem 1rem;border:0;border-radius:.4rem;background:#0b66c3;color:#fff;cursor:pointer">Save</button>
                </form>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- backend settings overlay: local models / coding agent / Ollama endpoint --%>
      <div :if={@settings} style="position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;z-index:10">
        <div style="background:var(--card);border:1px solid var(--bd2);border-radius:.6rem;width:min(58rem,95vw);height:86vh;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3)">
          <.agents_tabbar active={:backends} />
          <div style="overflow:auto;padding:1rem 1.2rem">
          <div style="color:var(--mut);font-size:.78rem;margin-bottom:.8rem">Settings the built-in agents read. Blank = default. Saved values apply to new threads (or re-pick the agent).</div>
          <form phx-change="settings_change" phx-submit="save_settings" style="display:flex;flex-direction:column;gap:.8rem">
            <datalist id="ollama_models"><option :for={m <- @settings.ollama} value={m} /></datalist>

            <div>
              <label style="font-size:.8rem;color:var(--mut)">Ollama endpoint</label>
              <div style="display:flex;gap:.4rem;margin-top:.2rem">
                <input name="ollama_url" value={@settings.form["ollama_url"]} placeholder="http://localhost:11434" style="flex:1;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-family:ui-monospace,monospace;font-size:.82rem" />
                <button type="button" phx-click="detect_ollama" style="padding:.35rem .7rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--card);color:var(--tx);cursor:pointer;font-size:.8rem">Detect</button>
              </div>
              <div style="font-size:.74rem;color:var(--mut);margin-top:.2rem">
                <%= if @settings.ollama == [] do %>No models detected (is Ollama running? URL correct?)<% else %>Detected (<%= length(@settings.ollama) %>): <%= Enum.join(@settings.ollama, ", ") %><% end %>
              </div>
            </div>

            <div>
              <label style="font-size:.8rem;color:var(--mut)">Strong / general local model</label>
              <input name="strong" list="ollama_models" value={@settings.form["strong"]} style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-family:ui-monospace,monospace;font-size:.82rem" />
            </div>

            <div>
              <label style="font-size:.8rem;color:var(--mut)">Cheap / fast local model <span style="opacity:.7">(for simple tasks; the Routed agent picks this vs the strong model)</span></label>
              <input name="cheap" list="ollama_models" value={@settings.form["cheap"]} style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-family:ui-monospace,monospace;font-size:.82rem" />
            </div>

            <div>
              <label style="font-size:.8rem;color:var(--mut)">Coding agent (ACP command)</label>
              <input name="coding_drive" value={@settings.form["coding_drive"]} placeholder="claude-code-acp" style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-family:ui-monospace,monospace;font-size:.82rem" />
              <div style={"font-size:.74rem;margin-top:.2rem;color:#{if @settings.acp, do: "#2ea043", else: "#d04437"}"}>
                <%= if @settings.acp, do: "✓ found: #{@settings.acp}", else: "✗ not on PATH (this agent won't run)" %>
              </div>
            </div>

            <div>
              <label style="font-size:.8rem;color:var(--mut)">Native Claude tool permission</label>
              <% perm = @settings.form["claude_permission"] || "" %>
              <select name="claude_permission" style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-size:.82rem">
                <option value="" selected={perm == ""}>Ask in the Console (🔐 Allow / Deny)</option>
                <option value="acceptEdits" selected={perm == "acceptEdits"}>Auto-accept edits (gate the rest)</option>
                <option value="bypassPermissions" selected={perm == "bypassPermissions"}>Full auto — Claude Code auto mode (no prompts)</option>
              </select>
              <div style="font-size:.74rem;margin-top:.2rem;color:var(--mut)">For the native "Claude Code (native CLI)" agent. Auto modes run autonomously without the 🔐 prompt.</div>
            </div>

            <div style="display:flex;gap:.6rem">
              <div style="flex:1">
                <label style="font-size:.8rem;color:var(--mut)">Native Claude model</label>
                <input name="claude_model" value={@settings.form["claude_model"] || ""} placeholder="default (e.g. opus / sonnet / claude-opus-4-8)" style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-family:ui-monospace,monospace;font-size:.82rem" />
              </div>
              <div style="width:11rem">
                <label style="font-size:.8rem;color:var(--mut)">Effort</label>
                <% eff = @settings.form["claude_effort"] || "" %>
                <select name="claude_effort" style="width:100%;margin-top:.2rem;padding:.35rem .5rem;border:1px solid var(--bd2);border-radius:.35rem;background:var(--panel);color:var(--tx);font-size:.82rem">
                  <option value="" selected={eff == ""}>default</option>
                  <option :for={lvl <- ~w(low medium high xhigh max)} value={lvl} selected={eff == lvl}><%= lvl %></option>
                </select>
              </div>
            </div>

            <div :if={@settings.saved} style="color:var(--ok-tx);background:var(--ok-bg);border:1px solid var(--ok-bd);border-radius:.4rem;padding:.4rem .6rem;font-size:.82rem"><%= @settings.saved %></div>

            <div style="display:flex;justify-content:flex-end;gap:.5rem">
              <button type="button" phx-click="close_settings" style="padding:.4rem .9rem;border:1px solid var(--bd2);border-radius:.4rem;background:var(--card);color:var(--tx);cursor:pointer">Close</button>
              <button type="submit" style="padding:.4rem 1rem;border:0;border-radius:.4rem;background:#0b66c3;color:#fff;cursor:pointer">Save</button>
            </div>
          </form>
          </div>
        </div>
      </div>

      <%!-- no-code agent builder: list + type-aware form -> generates custom_agents.jet --%>
      <div :if={@builder} style="position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;z-index:10">
        <div style="background:var(--card);width:min(58rem,95vw);height:88vh;border-radius:.6rem;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3)">
          <.agents_tabbar active={:builder} />
          <div style="flex:1;display:flex;overflow:hidden;min-height:0">
          <div style="width:15rem;flex-shrink:0;border-right:1px solid var(--bd);background:var(--panel);display:flex;flex-direction:column">
            <div style="padding:.5rem .6rem;font-weight:600;border-bottom:1px solid var(--bd);font-size:.84rem">Your agents</div>
            <div style="flex:1;overflow-y:auto;padding:.35rem">
              <button phx-click="builder_new" style="display:block;width:100%;text-align:left;border:1px dashed var(--bd2);border-radius:.35rem;background:none;color:var(--tx);cursor:pointer;padding:.4rem .5rem;font-size:.82rem;margin-bottom:.4rem">＋ New agent</button>
              <div :if={@builder.list == []} style="color:var(--mut);font-size:.78rem;padding:.3rem">No custom agents yet.</div>
              <div :for={a <- @builder.list} style="display:flex;align-items:center;gap:.15rem;margin:.1rem 0">
                <button phx-click="builder_edit" phx-value-key={a["key"]} style={"flex:1;text-align:left;border:0;border-radius:.3rem;cursor:pointer;padding:.3rem .45rem;font-size:.82rem;background:#{if @builder.form && @builder.form["key"] == a["key"], do: "var(--sel)", else: "transparent"};color:var(--tx);overflow:hidden;text-overflow:ellipsis;white-space:nowrap"}><%= a["label"] || a["key"] %> <span style="color:var(--mut);font-size:.68rem">· <%= a["type"] %></span></button>
                <button phx-click="builder_clone" phx-value-key={a["key"]} title="Duplicate" style="border:0;background:none;cursor:pointer;color:var(--mut);padding:.1rem .2rem">⧉</button>
                <button phx-click="builder_delete" phx-value-key={a["key"]} data-confirm="Delete this agent?" title="Delete" style="border:0;background:none;cursor:pointer;color:#c66;padding:.1rem .2rem">×</button>
              </div>
            </div>
          </div>

          <div style="flex:1;display:flex;flex-direction:column;padding:.7rem .9rem;min-width:0;overflow-y:auto">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.5rem">
              <strong style="font-size:.9rem">Compose an agent — no code</strong>
              <button phx-click="close_builder" style="border:0;background:none;cursor:pointer">Close ✕</button>
            </div>
            <div :if={@builder.form == nil} style="flex:1;display:flex;align-items:center;justify-content:center;padding:1rem">
              <div style="max-width:24rem;text-align:center;line-height:1.7;color:var(--mut);font-size:.88rem">Pick an agent on the left, or <strong>＋ New agent</strong>.<br />Saving generates <code style="background:var(--code);padding:.05rem .3rem;border-radius:.25rem">custom_agents.jet</code> and hot-loads it into the picker.</div>
            </div>

            <form :if={@builder.form} phx-change="builder_change" phx-submit="builder_save" style="display:flex;flex-direction:column;gap:.55rem">
              <% f = @builder.form %>
              <div style="display:flex;gap:.5rem">
                <label style="flex:1;font-size:.76rem;color:var(--mut)">Key (id)<input name="key" value={f["key"]} placeholder="my_agent" style={inp()} /></label>
                <label style="flex:2;font-size:.76rem;color:var(--mut)">Label<input name="label" value={f["label"]} placeholder="My Agent" style={inp()} /></label>
                <label style="flex:1;font-size:.76rem;color:var(--mut)">Type
                  <select name="type" style={inp()}>
                    <option :for={t <- ~w(simple tools shape routed)} value={t} selected={f["type"] == t}><%= t %></option>
                  </select>
                </label>
              </div>

              <div :if={f["type"] in ["simple", "tools", "shape"]} style="display:flex;gap:.5rem;align-items:flex-end">
                <label style="font-size:.76rem;color:var(--mut)">Backend
                  <select name="backend" style={inp()}>
                    <option value="drives" selected={f["backend"] == "drives"}>ACP command</option>
                    <option value="model" selected={f["backend"] == "model"}>Local model</option>
                  </select>
                </label>
                <label :if={f["backend"] == "drives"} style="flex:1;font-size:.76rem;color:var(--mut)">ACP command (any agent)<input name="drives" value={f["drives"]} placeholder="claude-code-acp / gemini-acp / …" style={inp()} /></label>
                <label :if={f["backend"] == "model"} style="flex:1;font-size:.76rem;color:var(--mut)">Local model<input name="model" value={f["model"]} placeholder="ollama:…" style={inp()} /></label>
              </div>

              <label :if={f["type"] in ["simple", "tools"]} style="font-size:.76rem;color:var(--mut)">Role / system prompt<textarea name="role" rows="3" style={inp()}><%= f["role"] %></textarea></label>

              <div :if={f["type"] == "tools"}>
                <div style="font-size:.76rem;color:var(--mut);margin-bottom:.25rem">Tools (run is gated by approve)</div>
                <div style="display:flex;flex-wrap:wrap;gap:.3rem .9rem">
                  <label :for={t <- Jc.AgentBuilder.tool_names()} style="font-size:.8rem;display:flex;align-items:center;gap:.25rem;font-family:ui-monospace,monospace"><input type="checkbox" name="tools[]" value={t} checked={t in (f["tools"] || [])} /><%= t %></label>
                </div>
                <label style="font-size:.76rem;color:var(--mut);display:block;margin-top:.4rem;width:9rem">Tool fuel<input name="tool_fuel" type="number" value={f["tool_fuel"]} style={inp()} /></label>
              </div>

              <div :if={f["type"] == "shape"} style="display:flex;flex-direction:column;gap:.5rem">
                <div style="display:flex;gap:.5rem">
                  <label style="flex:1;font-size:.76rem;color:var(--mut)">Runner
                    <select name="runner" style={inp()}>
                      <option :for={r <- Jc.AgentBuilder.runners()} value={r} selected={f["runner"] == r}><%= r %></option>
                    </select>
                  </label>
                  <label :if={f["runner"] == "Goal"} style="flex:1;font-size:.76rem;color:var(--mut)">Via (planner)
                    <select name="via" style={inp()}>
                      <option value="Architect" selected={f["via"] == "Architect"}>Architect (compose a team)</option>
                      <option value="Flow" selected={f["via"] == "Flow"}>Flow (dataflow graph)</option>
                      <option value="" selected={f["via"] == ""}>(none — single doer)</option>
                    </select>
                  </label>
                  <label style="width:6.5rem;font-size:.76rem;color:var(--mut)">Max rounds<input name="max_rounds" type="number" value={f["max_rounds"]} style={inp()} /></label>
                </div>
                <label :if={f["runner"] in ["Fleet", "Pipeline", "Debate", "Refine"]} style="font-size:.76rem;color:var(--mut)">Members — one per line <code>Name: role</code><span :if={f["runner"] == "Refine"}> (line 1 = writer, line 2 = critic)</span><textarea name="members_text" rows="4" placeholder="Risks: List the failure modes.&#10;Benefits: List the upsides." style={inp()}><%= f["members_text"] %></textarea></label>
                <label style="font-size:.76rem;color:var(--mut)">Accept condition — when is the goal done?<textarea name="accept" rows="2" style={inp()}><%= f["accept"] %></textarea></label>
                <label style="font-size:.8rem;display:flex;align-items:center;gap:.35rem"><input type="checkbox" name="surface" checked={f["surface"] == true} /> Surface the sub-shape's live work</label>
              </div>

              <div :if={f["type"] == "routed"} style="display:flex;flex-direction:column;gap:.5rem">
                <label style="font-size:.76rem;color:var(--mut)">Model pool — one per line <code>model | tier | lang | good_at</code><textarea name="rmodels_text" rows="4" placeholder="ollama:your-strong-model | strong | | coding, reasoning, hard tasks&#10;ollama:your-small-model | cheap | | short or simple tasks, drafts" style={inp()}><%= f["rmodels_text"] %></textarea></label>
                <div style="display:flex;gap:.5rem">
                  <label style="flex:1;font-size:.76rem;color:var(--mut)">Router model<input name="router" value={f["router"]} placeholder="ollama:…" style={inp()} /></label>
                  <label style="flex:1;font-size:.76rem;color:var(--mut)">Checker model<input name="checker" value={f["checker"]} placeholder="ollama:…" style={inp()} /></label>
                  <label style="width:6.5rem;font-size:.76rem;color:var(--mut)">Max rounds<input name="max_rounds" type="number" value={f["max_rounds"]} style={inp()} /></label>
                </div>
                <label style="font-size:.76rem;color:var(--mut)">Accept condition<textarea name="accept" rows="2" style={inp()}><%= f["accept"] %></textarea></label>
              </div>

              <div :if={@builder.error} style="color:var(--err-tx);background:var(--err-bg);border:1px solid var(--err-bd);border-radius:.4rem;padding:.4rem .6rem;font-size:.8rem"><%= @builder.error %></div>
              <div :if={@builder.saved} style="color:var(--ok-tx);background:var(--ok-bg);border:1px solid var(--ok-bd);border-radius:.4rem;padding:.4rem .6rem;font-size:.82rem"><%= @builder.saved %></div>
              <div style="display:flex;justify-content:flex-end;gap:.5rem">
                <button type="submit" style="padding:.45rem 1.2rem;border:0;border-radius:.4rem;background:#0b66c3;color:#fff;cursor:pointer">Save + load</button>
              </div>
            </form>
          </div>
          </div>
        </div>
      </div>

      <%!-- P2: parallel-agents board — a grid of thread cards (status + RUN summary); click to open --%>
      <div :if={@board} style="position:fixed;inset:0;background:var(--bg);z-index:20;display:flex;flex-direction:column;padding:1rem 1.2rem">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.8rem">
          <strong style="font-size:1rem">▦ Agents<span :if={running_count(@threads) > 0} style="color:#d9a23b;font-weight:400;font-size:.85rem"> · <%= running_count(@threads) %> running</span></strong>
          <button phx-click="toggle_board" style="border:0;background:none;cursor:pointer">Close ✕</button>
        </div>
        <div style="flex:1;overflow-y:auto;display:grid;grid-template-columns:repeat(auto-fill,minmax(21rem,1fr));gap:.7rem;align-content:start">
          <div :for={t <- threads_of(@threads, @current_project)} phx-click="board_open" phx-value-id={t.id} style="cursor:pointer;border:1px solid var(--bd2);border-radius:.5rem;padding:.7rem .8rem;background:var(--card);display:flex;flex-direction:column;gap:.4rem;overflow:hidden">
            <% st = thread_status(t) %>
            <div style="display:flex;align-items:center;gap:.4rem">
              <span style={"display:inline-block;width:.55rem;height:.55rem;border-radius:50%;flex-shrink:0;#{status_dot_style(st)}"}></span>
              <strong style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.88rem"><%= t.title %></strong>
              <span style="font-size:.68rem;color:var(--mut)"><%= st %></span>
            </div>
            <div style="font-size:.73rem;color:var(--mut);display:flex;gap:.5rem;align-items:center;min-width:0">
              <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= backend_label(t.backend, @agents) %></span>
              <span :if={t.worktree} style="color:#2ea043;flex-shrink:0">🌳 <%= t.worktree.branch %></span>
            </div>
            <div :if={Map.get(@traces, t.id, []) != []} style="border-top:1px solid var(--bd);padding-top:.35rem;max-height:8.5rem;overflow:hidden">
              <div :for={{e, d} <- trace_tree_order(Map.get(@traces, t.id, []))} style={"font-size:.72rem;font-family:ui-monospace,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding-left:#{d * 0.7}rem"}><%= trace_icon(e.status) %> <%= e.label %><span style="color:var(--mut)"><%= trace_ms(e) %></span></div>
            </div>
          </div>
        </div>
      </div>

    </div>
    """
  end
end
