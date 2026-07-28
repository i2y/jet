defmodule Jc.AgentStore do
  @moduledoc """
  Discovers, compiles, hot-loads, and edits the Jet agent-definition files that drive the
  console's backend picker. Each `.jet` file is a Jet module exporting `catalog/0`
  ([{key, "Label"}]) and `spawn_for/1` (key -> agent pid). Files are scanned from TWO dirs: the
  shipped built-ins (`builtin_dir`) and the user's own agents (`user_dir`, writable, where the
  no-code builder regenerates `custom_agents.jet`). Editing/compiling hot-loads the new beam — no
  server restart.
  """

  def jet_root,
    do: System.get_env("JET_ROOT") || :persistent_term.get({:jc, :jet_root}, File.cwd!())

  @doc "the shipped, editable built-in agents (builtin.jet)."
  def builtin_dir, do: System.get_env("JET_AGENTS_DIR") || Path.join(jet_root(), "console/agents")

  @doc "the user's writable agents dir (where the builder writes custom_agents.json/.jet)."
  def user_dir do
    System.get_env("JET_USER_AGENTS_DIR") ||
      Path.join(to_string(:filename.basedir(:user_config, ~c"jet_console")), "agents")
  end

  # both dirs (deduped, existing-or-creatable); built-ins first so they win the fallback.
  defp dirs, do: Enum.uniq([builtin_dir(), user_dir()])

  defp escript, do: Path.join(jet_root(), "jet")

  @doc "full paths of every agent .jet across both dirs."
  def paths do
    for d <- dirs(),
        File.dir?(d),
        f <- File.ls!(d) |> Enum.filter(&String.ends_with?(&1, ".jet")) |> Enum.sort() do
      Path.join(d, f)
    end
  end

  defp module_of(path), do: path |> Path.basename(".jet") |> String.to_atom()

  @doc "compile + hot-load every agent file (call at boot)."
  def load_all do
    Enum.each(dirs(), &Code.append_path(String.to_charlist(&1)))
    Enum.each(paths(), &compile_load/1)
  end

  @doc "re-scan, recompile + hot-load everything (after the builder regenerates a file)."
  def reload, do: load_all()

  @doc "compile one .jet (full path) with the jet escript and hot-load it. :ok | {:error, output}"
  def compile_load(path) do
    case System.cmd(escript(), [path], cd: jet_root(), stderr_to_stdout: true) do
      {_out, 0} ->
        mod = module_of(path)
        :code.purge(mod)
        :code.load_file(mod)
        :ok

      {out, _} ->
        {:error, out}
    end
  rescue
    e -> {:error, "could not run the jet compiler (#{escript()}): #{Exception.message(e)}"}
  end

  @doc "the aggregated picker list: [{module, key, label}] across all loaded agent files."
  def catalog do
    for path <- paths(),
        mod = module_of(path),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :catalog, 0),
        {key, label} <- safe_catalog(mod) do
      {mod, key, to_string(label)}
    end
  end

  defp safe_catalog(mod) do
    mod.catalog()
  rescue
    _ -> []
  end

  @doc "spawn an agent given a module + key (from a catalog entry)."
  def spawn_agent(mod, key) when is_atom(mod) and is_atom(key), do: mod.spawn_for(key)

  # --- raw file editor (the ⚙ panel) operates on the built-in dir ---
  def files do
    case File.ls(builtin_dir()) do
      {:ok, fs} -> fs |> Enum.filter(&String.ends_with?(&1, ".jet")) |> Enum.sort()
      _ -> []
    end
  end

  def read(file), do: File.read(Path.join(builtin_dir(), file))
  def write(file, content), do: File.write(Path.join(builtin_dir(), file), content)

  def delete(file) do
    File.rm(Path.join(builtin_dir(), file))
    mod = file |> Path.basename(".jet") |> String.to_atom()
    :code.purge(mod)
    :code.delete(mod)
    :ok
  end

  @doc "a skeleton for a new agent file."
  def template(name) do
    """
    module #{name}
      agent MyAgent
        model jet_settings::strong()   # the model picked in Settings (or set "ollama:your-model")
        role "You are a helpful assistant."
        expose chat(message)
      end

      def self.catalog()
        [{:my_agent, "My Agent (#{name})"}]
      end

      def self.spawn_for(key)
        #{name}::MyAgent.spawn()
      end
    end
    """
  end
end
