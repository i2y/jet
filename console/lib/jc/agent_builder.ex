defmodule Jc.AgentBuilder do
  @moduledoc """
  No-code agent builder. Agent configs are stored as JSON (the source of truth) in the user agents
  dir; from them we GENERATE a single Jet module (`custom_agents.jet`) that the AgentStore compiles
  and hot-loads. Editing round-trips through the JSON (we never parse the generated .jet back).

  Config shape (per agent):
    %{ "key","label","type" ("simple"|"tools"|"shape"|"routed"),
       "backend" ("model"|"drives"), "model","drives","role","tool_fuel",
       "tools" [names], "runner","via","accept","max_rounds","surface",
       "members" [%{"name","role"}], "rmodels" [%{"name","tier","lang","good_at"}],
       "router","checker" }
  """

  @tool_lib %{
    "read_file" => "tool read_file(path: String) do |p| jet_fs::read(p) end",
    "write_file" =>
      "tool write_file(path: String, content: String) do |p, c| jet_fs::write(p, c) end",
    "edit_file" =>
      "tool edit_file(path: String, old: String, new: String) do |p, o, n| jet_fs::edit(p, o, n) end",
    "list_dir" => "tool list_dir(path: String) do |p| jet_fs::list(p) end",
    "grep" => "tool grep(pattern: String, path: String) do |pat, p| jet_fs::grep(pat, p) end",
    "run" =>
      "tool run(command: String) do |c| os::cmd(erlang::binary_to_list(erlang::iolist_to_binary(c))) end",
    "web_search" => "tool web_search(query: String) do |q| jet_web::search(q) end",
    "web_fetch" => "tool web_fetch(url: String) do |u| jet_web::fetch(u) end"
  }

  def tool_names, do: Map.keys(@tool_lib) |> Enum.sort()
  def runners, do: ~w(Goal Fleet Pipeline Debate Refine)

  def json_path, do: Path.join(Jc.AgentStore.user_dir(), "custom_agents.json")
  def jet_path, do: Path.join(Jc.AgentStore.user_dir(), "custom_agents.jet")

  @doc "the list of saved agent configs (source of truth)."
  def load do
    with {:ok, body} <- File.read(json_path()),
         {:ok, list} when is_list(list) <- Jason.decode(body) do
      list
    else
      _ -> []
    end
  end

  def get(key), do: Enum.find(load(), &(&1["key"] == key))

  @doc "insert/replace one agent (by key) and regenerate."
  def put(agent) when is_map(agent) do
    key = agent["key"]
    list = load()

    list =
      if Enum.any?(list, &(&1["key"] == key)),
        do: Enum.map(list, fn a -> if a["key"] == key, do: agent, else: a end),
        else: list ++ [agent]

    save_all(list)
  end

  def delete(key), do: save_all(Enum.reject(load(), &(&1["key"] == key)))

  def save_all(list) when is_list(list) do
    File.mkdir_p!(Jc.AgentStore.user_dir())
    File.write!(json_path(), Jason.encode!(list, pretty: true))
    regenerate(list)
    list
  end

  @doc "write custom_agents.jet from the configs (or remove it if none) and hot-reload."
  def regenerate(list \\ load()) do
    case list do
      [] -> File.rm(jet_path())
      _ -> File.write!(jet_path(), codegen(list))
    end

    Jc.AgentStore.reload()
  end

  # --- codegen -------------------------------------------------------------

  def codegen(list) do
    blocks = list |> Enum.map(&agent_block/1) |> Enum.join("\n\n")

    catalog =
      list
      |> Enum.map(fn a -> "{:#{akey(a)}, #{jstr(a["label"] || a["key"])}}" end)
      |> Enum.join(",\n     ")

    clauses =
      list
      |> Enum.map(fn a -> "      case :#{akey(a)}\n        custom_agents::#{mod(a)}.spawn()" end)
      |> Enum.join("\n")

    first = mod(List.first(list))

    """
    module custom_agents
    #{blocks}

      def self.catalog()
        [#{catalog}]
      end

      def self.spawn_for(key)
        match key
    #{clauses}
          case _
            custom_agents::#{first}.spawn()
        end
      end
    end
    """
  end

  defp agent_block(a) do
    body =
      case a["type"] do
        "shape" -> "    runner #{runner_decl(a)}"
        "routed" -> "    runner #{routed_decl(a)}"
        "tools" -> simple_body(a, tool_block(a))
        _ -> simple_body(a, "")
      end

    "  agent #{mod(a)}\n#{body}\n    expose chat(message)\n  end"
  end

  # simple / tools: a backend + role (+ optional tools/on_approval/fuel)
  defp simple_body(a, tools) do
    [
      backend_line(a),
      fuel_line(a),
      "    role #{jstr(a["role"] || "You are a helpful assistant.")}",
      tools
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp backend_line(a) do
    case a["backend"] do
      "drives" -> "    drives #{jstr(a["drives"] || "claude-code-acp")}"
      _ -> "    model #{mexpr(a["model"])}"
    end
  end

  # a model value for the generated .jet: the explicit string if set, else jet_settings::strong()
  # (the user's configured strong model) -- never a hardcoded machine-specific model name.
  defp mexpr(v) when is_binary(v) and v != "", do: jstr(v)
  defp mexpr(_), do: "jet_settings::strong()"

  defp fuel_line(a) do
    case a["tool_fuel"] do
      n when is_integer(n) and n > 0 -> "    tool_fuel #{n}"
      _ -> ""
    end
  end

  defp tool_block(a) do
    names = a["tools"] || []

    tools =
      names
      |> Enum.map(&Map.get(@tool_lib, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("    " <> &1))

    gate =
      if "run" in names,
        do: [
          "    def on_approval(req)",
          "      jet_policy::gate(req, <<\"run\">>, {|r| jet_policy::deny_tokens(r, jet_policy::default_deny())})",
          "    end"
        ],
        else: []

    Enum.join(tools ++ gate, "\n")
  end

  # shape: Goal/Fleet/Pipeline/Debate/Refine
  defp runner_decl(a) do
    bk = backend_opt(a)
    mr = if n = int(a["max_rounds"]), do: "max_rounds: #{n}", else: nil

    case a["runner"] do
      "Fleet" ->
        opts =
          compact([
            members_opt("members", a),
            "reduce: #{jstr(a["accept"] || "Synthesize the members' outputs into one clear answer.")}",
            bk
          ])

        "Fleet(#{opts})"

      "Pipeline" ->
        "Pipeline(#{compact([members_opt("stages", a), bk])})"

      "Debate" ->
        opts =
          compact([
            members_opt("agents", a),
            "rounds: #{int(a["max_rounds"]) || 2}",
            "judge: {role: #{jstr("Weigh the sides and give a decisive verdict.")}}",
            bk
          ])

        "Debate(#{opts})"

      "Refine" ->
        [w, c] = two_members(a)
        "Refine(#{compact(["worker: {role: #{jstr(w)}}", "critic: {role: #{jstr(c)}}", mr, bk])})"

      _ ->
        via =
          case a["via"] do
            v when v in ["Architect", "Flow"] -> "via: {name: :#{v}}"
            _ -> nil
          end

        sur = if a["surface"] == true, do: "surface: true", else: nil
        acc = if x = nonempty(a["accept"]), do: "accept: #{jstr(x)}", else: nil
        "Goal(#{compact([via, acc, sur, mr, bk])})"
    end
  end

  defp routed_decl(a) do
    models =
      (a["rmodels"] || [])
      |> Enum.map(&rmodel/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(",\n               ")

    acc =
      if x = nonempty(a["accept"]),
        do: "accept: #{jstr(x)}",
        else: "accept: #{jstr("The reply directly and correctly answers the request.")}"

    "Goal(\n      models: [#{models}],\n      select: :route,\n      router: #{mexpr(a["router"])},\n      checker: #{mexpr(a["checker"] || a["router"])},\n      max_rounds: #{int(a["max_rounds"]) || 1},\n      #{acc})"
  end

  defp rmodel(m) do
    case nonempty(m["name"]) do
      nil ->
        nil

      name ->
        extra =
          compact([
            if(t = nonempty(m["tier"]), do: "tier: :#{t}", else: nil),
            if(l = nonempty(m["lang"]), do: "lang: :#{l}", else: nil),
            if(g = nonempty(m["good_at"]), do: "good_at: #{jstr(g)}", else: nil)
          ])

        "{name: #{jstr(name)}#{if extra == "", do: "", else: ", " <> extra}}"
    end
  end

  defp backend_opt(a) do
    case a["backend"] do
      "drives" -> "drives: #{jstr(a["drives"] || "claude-code-acp")}"
      "model" -> "model: #{mexpr(a["model"])}"
      _ -> nil
    end
  end

  defp members_opt(key, a) do
    ms =
      (a["members"] || [])
      |> Enum.map(fn m ->
        "{name: #{jstr(m["name"] || "Member")}, role: #{jstr(m["role"] || "Do your part.")}}"
      end)
      |> Enum.join(",\n                 ")

    "#{key}: [#{ms}]"
  end

  defp two_members(a) do
    ms = a["members"] || []
    w = (Enum.at(ms, 0) || %{})["role"] || "Produce the requested output."

    c =
      (Enum.at(ms, 1) || %{})["role"] ||
        "Critique the draft against the task; reply APPROVED when it fully satisfies it."

    [w, c]
  end

  # --- helpers -------------------------------------------------------------

  defp compact(list), do: list |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")
  defp mod(a), do: Macro.camelize(akey(a))

  defp akey(a),
    do: a["key"] |> to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.downcase()

  defp int(n) when is_integer(n), do: n

  defp int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp nonempty(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp nonempty(_), do: nil

  # a Jet binary string literal, safely escaped (no #{} interpolation surprises).
  defp jstr(s) do
    esc =
      to_string(s)
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "")
      |> String.replace("\t", "\\t")

    "<<\"" <> esc <> "\">>"
  end
end
