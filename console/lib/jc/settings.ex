defmodule Jc.Settings do
  @moduledoc """
  Per-user backend settings for the portable built-in agents: which local models fill the
  strong/JA roles, which coding agent to drive over ACP, and the Ollama endpoint. Persisted as
  JSON in the user config dir and APPLIED to the env vars that `jet_settings` (Jet) reads, so the
  built-ins point at the user's own environment without editing agent definitions. Also detects
  what's installed (Ollama models, the ACP command) so the Settings UI can offer real choices.
  """

  # settings key -> the env var jet_settings reads
  @env %{
    "strong" => "JET_MODEL_STRONG",
    "cheap" => "JET_MODEL_CHEAP",
    "coding_drive" => "JET_CODING_DRIVE",
    "ollama_url" => "JET_OLLAMA_URL",
    # native Claude tool permission: "" (unset) = ask in the Console 🔐; "acceptEdits" / "bypassPermissions"
    # = Claude Code's auto modes (no prompts). Read by src/jet_claude.jet.
    "claude_permission" => "JET_CLAUDE_PERMISSION",
    # native Claude --model (opus/sonnet/fable or a full name) + --effort (low/medium/high/xhigh/max);
    # "" = the CLI's own default. Read by src/jet_claude.jet.
    "claude_model" => "JET_CLAUDE_MODEL",
    "claude_effort" => "JET_CLAUDE_EFFORT"
  }

  # must mirror the defaults baked into src/jet_settings.jet. The local model slots are EMPTY by
  # default (every machine has different Ollama models) — the Settings UI detects what is installed
  # and the user picks; until then the local agents report "no model set". coding_drive/ollama_url
  # have sensible standard defaults.
  @defaults %{
    "strong" => "",
    "cheap" => "",
    "coding_drive" => "claude-code-acp",
    "ollama_url" => "http://localhost:11434"
  }

  def defaults, do: @defaults
  def keys, do: Map.keys(@env)

  def path do
    System.get_env("JET_CONSOLE_SETTINGS") ||
      Path.join(to_string(:filename.basedir(:user_config, ~c"jet_console")), "settings.json")
  end

  @doc "the raw saved map (only explicitly-set keys), or %{}."
  def load do
    with {:ok, body} <- File.read(path()),
         {:ok, m} when is_map(m) <- Jason.decode(body) do
      m
    else
      _ -> %{}
    end
  end

  @doc "the EFFECTIVE value for a key: saved value, else the default."
  def get(key, map \\ load()), do: nonempty(Map.get(map, key)) || @defaults[key]

  @doc "persist a settings map (keeps only known, non-empty keys) and apply it to the env."
  def save(map) when is_map(map) do
    clean =
      map
      |> Map.take(keys())
      |> Enum.flat_map(fn {k, v} -> if x = nonempty(v), do: [{k, x}], else: [] end)
      |> Map.new()

    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(clean, pretty: true))
    apply_env(clean)
    clean
  end

  @doc "set the env vars jet_settings reads (non-empty -> set; missing -> cleared so the default applies). Call at boot."
  def apply_env(map \\ load()) do
    Enum.each(@env, fn {k, env} ->
      case nonempty(Map.get(map, k)) do
        nil -> System.delete_env(env)
        v -> System.put_env(env, v)
      end
    end)
  end

  # --- detection ---

  @doc "installed Ollama model names at the (configured or given) endpoint, or [] if unreachable."
  def ollama_models(url \\ nil) do
    u = url || get("ollama_url")

    case Req.get(u <> "/api/tags", receive_timeout: 2500, retry: false) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        models |> Enum.map(&Map.get(&1, "name")) |> Enum.filter(&is_binary/1) |> Enum.sort()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc "resolved path of the coding-agent command on PATH (first token of the drive), or nil."
  def acp_path(cmd \\ nil) do
    bin = (cmd || get("coding_drive")) |> String.split() |> List.first() || ""
    if bin == "", do: nil, else: System.find_executable(bin)
  end

  defp nonempty(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp nonempty(_), do: nil
end
