# The `agent` DSL

Read this when the task involves an `agent` — declaring one, changing its backend, giving it tools,
picking a collaboration shape, or serving it over a protocol. For plain language questions see
`language.md`; for the traps that will bite you regardless, stay with `SKILL.md`.

An `agent` desugars to an `actor` (an OTP gen_server) plus a pluggable **runner**. That is the whole
idea: the agent is a supervised BEAM process, and the runner decides what a turn actually does.

## Anatomy

```jet
agent Researcher
  runner Llm(model: "ollama:qwen3.6:35b-a3b")   # THE backend form
  role "You research rigorously and cite sources."
  workspace "./src"                             # fs sandbox root (ACP runners)
  memory "researcher-main"                      # see Memory below
  skills "./skills"                             # a dir of SKILL.md dirs
  mcp "npx -y @modelcontextprotocol/server-filesystem /tmp"
  tool web_search                               # a peer agent / function / MCP tool
  tool price(item: String), "Catalog price" do |i|
    4217
  end

  expose research(question) -> {answer: String, sources: [String]}

  def on_approval(req)                          # permission policy
    match req.get(:kind)
      case "execute"
        :deny
      case _
        :allow
    end
  end
end
```

`model X` and `drives "cmd"` are shorthands for `runner Llm(model: X)` and
`runner Acp(command: "cmd")`. Both parse a full **expression**, so
`model jet_settings::strong()` is legal and is evaluated at spawn — that is how the shipped
built-in agents avoid hardcoding anyone's model.

## `expose` and what the return type means

`expose` is literally the same keyword an `actor` uses. The **return type** decides how the turn
comes back, so there is no second keyword to learn:

| Declaration | You get |
|---|---|
| `expose chat(msg)` | free text |
| `expose ask(q) -> {answer: String}` | a value coerced to that schema — a **contract** |
| `expose fix(desc) -> TurnResult` | the work the agent did: `.text` `.ok?` `.edits` `.plan` `.files` `.tool_calls` `.commands` |

`ask m(...)` and `task m(...)` are older aliases for `expose` and still work.

Calls are **async**. They return a future:

```jet
r = Researcher.spawn()
r.research("What is the BEAM?").await()     # => {:ok, value} | {:error, reason}

r.research("...").stream do |ev|            # watch the turn as it happens
  match ev
    case {:text, s}        io::format("~ts", [s])
    case {:thought, s}     :ok
    case {:tool_call, t}   io::format("-> ~ts~n", [t.get(:title)])
    case {:plan, steps}    :ok
    case {:usage, u}       :ok               # tokens / cost
    case {:prompt, p}      :ok               # the request as actually sent
    case _                 :ok
  end
end
```

Because a declared `-> Type` is enforced, **always match the result**. A reply that cannot satisfy
the schema is `{:error, {:schema_mismatch, …}}`, naming the field — it is never handed back as raw
text. That enforcement lives in exactly one place (`jet_sap`), for every runner and every shape.

## Runners

`jet_agent::known_runners/0` is the authority. Two are primitives:

- **`Llm`** — Jet runs the LLM turn itself. `model "ollama:<name>"` uses local Ollama with
  schema-constrained output; any other model id goes to a hosted provider (set `provider:` and an
  API key). `model:` is required — there is deliberately no default model.
- **`Acp`** — drive an *external* agent over the Agent Client Protocol: `drives "claude-code-acp"`,
  `drives "npx @zed-industries/codex-acp"`, or `drives "claude"` for the Claude CLI with no adapter.

Then the **collaboration shapes**, each of which is one `jet_<name>` module over the same substrate:

| Runner | Shape |
|---|---|
| `Fleet` | parallel fan-out + synthesis; `workspace: :worktree` for parallel codegen; `nodes:`/`retry:` to spread members across BEAM nodes |
| `Pipeline` | sequential stages |
| `Refine` | draft ⇄ critique loop |
| `Debate` | debaters + a judge |
| `Goal` | iterate until an acceptance check passes |
| `Auto` | a router picks from a listed `shapes:` menu |
| `Architect` | invents the team, then picks a built-in shape |
| `Flow` | generates an arbitrary dataflow graph — the most dynamic |
| `Plan` | plan-then-execute |
| `Fake` | canned `replies:` that still go through schema parsing — for tests |

Unknown runner names are an error listing the known ones, and unrecognised option keys are rejected
before the turn runs (each shape declares its own `runner_opts_spec/0`). If you get such an error,
read that function in `src/jet_<shape>.jet` rather than guessing.

Several shapes accept a `models:` pool with `select: :escalate` (cheap first, escalate on failure)
or `select: :route` (a cheap router picks once per task).

## Testing without a model, a key or a network

`runner Fake(replies: …)` is the reason Jet agent programs are testable. `replies:` takes a value, a
`{method: reply}` map, or a `fn(method, args)`, and the canned text still goes through the same
schema parsing a real reply does — so the test pins down what your program actually receives when a
model wraps JSON in a fence or forgets a field.

```jet
agent Desk
  role "You are a parts desk."
  runner Fake(replies: "{\"answer\": \"4217\"}")
  expose ask(q) -> {answer: String}
end
```

Prefer this to mocks. See `examples/agent_fake_test.jet` in the Jet repo.

## Memory

`memory "<a string>"` is durable and snapshot-backed (it survives restart). `memory :session` (or no
`memory` at all) is ephemeral in-RAM. `memory :fresh` means stateless. A byte-budgeted window of
recent turns plus a rolling summary is what actually reaches the prompt, so a long thread is not
re-sent whole.

## Serving an agent over a protocol

The same file, no serve boilerplate:

```sh
jet acp-serve mod::Agent::method file.jet    # any ACP client (an editor) drives it
jet mcp-serve mod::Agent::method file.jet    # any MCP client drives it
```

Over MCP the agent *is* all three primitives: **tools** are its exposed methods plus its `tool`
declarations, **resources** are its role/composition/memory, **prompts** are its declared `skills`.
A `tools/call` runs in its own process, progress streams as `notifications/progress` when the client
sends a `_meta.progressToken`, and `notifications/cancelled` ends the turn without killing the agent.

In the other direction an agent **consumes** external servers with `mcp "<command>"`; their tools
become callable mid-turn. That connection is bidirectional — the server's `ping`, `roots/list` and
`sampling/createMessage` are answered, sampling on the agent's own backend.

## Observability

Set `OTEL_EXPORTER_OTLP_ENDPOINT` and each turn becomes one OpenTelemetry trace: a
`jet.agent.turn` root span, every shape node nested under its real parent, and backend and tool
spans carrying the `gen_ai.*` semantic conventions. It is off, at zero cost, until an endpoint is
set — there is nothing to add to an agent to make it observable.
