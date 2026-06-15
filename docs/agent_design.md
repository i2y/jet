# Jet `agent` — Design Note

Status: design (Phase 4). Builds on the unified actor state model (actor state =
threaded gen_server state; see the "actor state unification" change).

## 1. Goal

Add a third execution strategy alongside `class` and `actor`:

| keyword | what it is | dispatch | ~cost/call (measured) |
|---------|------------|----------|-----------------------|
| `class` | immutable value object | direct (`call_method`) | ~48 ns |
| `actor` | OTP gen_server process | message round-trip | ~580 ns |
| `agent` | LLM / agent-backed entity | structured request → runner | ~ms–s |

The thesis: **object = actor = agent**, one object model and call syntax
(`x.method()`) spanning local value → concurrent process → AI agent. `agent` is
the construct that makes Jet distinctive on the BEAM and is the natural home for
multi-agent orchestration.

Two non-negotiables learned in design discussion:

1. **Agents differ in *kind*, not degree** (nondeterminism, $ cost, latency
   ~10^8× a class call, failure/refusal, streaming). The call site must surface
   that — **async by default** (calls return a `Future`; `.await()` / `.stream{}`).
2. **The keyword stays thin.** `agent` desugars to `actor` + a pluggable
   **runner**. All fast-moving LLM/agent-protocol detail lives in libraries, not
   the compiler. `agent` : `actor` :: `actor` : `gen_server`.

## 2. Surface syntax

Two method kinds, by result shape — **`ask`** (a typed answer) and **`task`** (a
`TurnResult`: the work the agent did). Backend by form — **`model`** (in-process
LLM) / **`drives`** (external ACP agent). (`runner Llm/Acp(...)` and `expose -> T`
remain as the underlying/alias forms.)

```ruby
# a thinking machine: typed answers (Llm)
agent Researcher
  model "claude-opus-4-8"
  role "You research rigorously and cite sources."

  ask research(question) -> {answer: String, sources: [String]}
  ask critique(draft)    -> {issues: [String], score: Int}

  tool web_search, Summarizer          # other actors/agents/MCP become tools
end

# an external coding agent: work -> TurnResult (Acp)
agent Coder
  drives "claude-code-acp"
  role "Test-driven."
  workspace "./src"                    # fs sandbox root
  memory :session                      # :session (default) | :fresh

  task fix(description)
  task refactor(target, goal)

  approve do |req|                     # permission policy
    match req.get(:kind)
      case "execute"
        :deny
      case _
        :allow
    end
  end
end
```

```ruby
r = Researcher.spawn()
r.research("BEAM scheduler design?").await()       # {:ok, {answer, sources}} (typed)

Coder.spawn().fix("make tests pass").stream do |ev|   # structured turn events
  display(ev)        # {:plan, _} | {:tool_call, _} | {:text, _} | {:thought, _}
end                                                # returns a TurnResult
```

## 3. Desugar: `agent` → `actor` + runner

`agent Foo` compiles to an `actor` (gen_server) whose state holds the
conversation/Thread + runner_state + config (all threaded via the unified actor
state model). Each `expose m(args) -> schema` has no body; it desugars to:

```ruby
def m(self, args...)
  req = {method: :m, args: {...}, schema: <schema(m)>, thread: @thread}
  {result, rs2, thread2} = Runner.turn(@runner, @runner_state, req)
  @runner_state = rs2     # threaded => conversation continuity (sys:get_state inspectable)
  @thread = thread2
  validate(result, <schema(m)>)   # retry/error on mismatch
end
```

Calls are **async by default**: `r.research(q)` returns a `Future`. The agent
processes one turn at a time (a conversation is sequential); streaming delivers
items to the subscriber process; the caller is never blocked.

## 4. Runner interface (the swap point)

A runner is a library behavior:

```
start(config)                          -> runner_state
turn(runner_state, request)            -> {result, runner_state}
stream_turn(runner_state, request, cb) -> {result, runner_state}
register_tools(runner_state, tools)    -> runner_state
stop(runner_state)
```

`request = {method, args, output_schema, thread}`. The agent's gen_server holds
`runner_state` (Acp: subprocess port; Llm: message history) in its @state.

## 5. `Llm` runner (a) — Jet runs the loop (pydantic-ai, on BEAM)

```
start: init LlmAdapter; system prompt = role; register MCP tools
turn:  1. append structured {method, args} to history
       2. call LLM (history + tools=function-calling + output_schema=structured output)
       3. LLM tool call -> invoke the Jet actor/agent method -> append result -> loop
       4. final structured output -> validate vs schema -> {result, new history}
```

Tools use an **MCP client** (10k+ existing tool servers for free). Each agent is
a supervised gen_server.

## 6. `Acp` runner (b) — drive external agents via Agent Client Protocol

> Full message-level sequences (connection, turn, tool_call, streaming,
> multi-turn) with mermaid diagrams: **[`acp_sequence.md`](acp_sequence.md)**.

ACP (Agent Client Protocol, JSON-RPC 2.0) is an open standard for a client to
drive a coding/agent runtime. One runner drives
**Codex / Claude Code / Gemini / any ACP agent** through a single standard runner.

Note: ACP and Codex's **App Server** are *distinct* wire protocols — both
JSON-RPC/JSONL over stdio, but not interchangeable (the App Server is OpenAI's
Codex-specific protocol). So the `Acp` runner does **not** speak to
`codex app-server` directly; it drives Codex through the official ACP adapter
**`@zed-industries/codex-acp`** (exactly as it drives Claude Code through
`claude-code-acp`). Driving the raw App Server would be a separate
`CodexAppServer` runner — only worth it to drop the Node adapter or to reach
Codex-specific surface.

Terminology: ACP "agent" = the external LLM tool; Jet `agent` = the actor that is
the ACP **client**.

### Lifecycle / method mapping (verified against ACP schema v1)

| Jet actor event | ACP method | dir | notes |
|---|---|---|---|
| `Foo.spawn` → init | spawn subprocess + `initialize` | C→A | negotiate protocolVersion + capabilities |
| (if needed) | `authenticate` | C→A | API key / login |
| create conversation | `session/new` → sessionId | C→A | sessionId stored in @state = the Thread |
| resume persisted conv | `session/load` / `session/resume` | C→A | inspectable via `sys:get_state` |
| `r.m(args)` call | `session/prompt` (PromptRequest) | C→A | method+args → ContentBlock(s); returns PromptResponse{stopReason} |
| streaming | `session/update` (SessionNotification) | A→C | see update variants below → `.stream{}` |
| approval | `session/request_permission` | A→C | → `on_approval` hook → RequestPermissionOutcome |
| agent file I/O | `fs/read_text_file` / `fs/write_text_file` | A→C | Jet serves from sandboxed Workspace (PathSafety) |
| agent shell | `terminal/create|output|kill|release|wait_for_exit` | A→C | Jet serves sandboxed terminal |
| cancel | `session/cancel` (CancelNotification) | C→A | Future cancel / timeout |
| shutdown | `session/close` + kill subprocess | C→A | actor terminate |

Other methods available: `session/list`, `session/delete`, `session/set_mode`,
`session/set_config_option`.

### Turn flow for one `r.research(q)`

1. PromptRequest `{sessionId, prompt: [ContentBlock(text|...)]}` from method+args.
2. Send `session/prompt`; concurrently receive `session/update` notifications:
   `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`
   (status: pending/in_progress/completed/failed), `plan`,
   `available_commands_update`, `current_mode_update` → forwarded to `.stream{}`.
3. Serve agent→client callbacks during the turn: `session/request_permission`
   → `on_approval` (outcomes: allow_once/allow_always/reject_once/reject_always);
   `fs/*` and `terminal/*` → from the agent's sandboxed Workspace.
4. PromptResponse returns `stopReason`: `end_turn` | `refusal` | `cancelled` |
   `max_tokens` | `max_turn_requests`.
5. Map to `-> schema`: parse the accumulated agent message into the output schema.
   `refusal` → `{:error, :refusal}`; `end_turn` → validate → typed Jet value.

ContentBlock kinds: text, image, audio, resource, resource_link.

### Schema bridge

ACP turns are conversational (text in/out). To honor `-> {…}`, the Acp runner
instructs the agent (via prompt/system text) to emit a final JSON matching the
schema and validates it (retry on parse failure). If/when the target agent
supports native structured output, request it directly.

### Tools with the Acp runner

The external agent has its own tools. Jet's `tools` (peers) are exposed to it by
**running an MCP server** (Jet actors/agents as MCP tools) that the external agent
connects to. So `tools` is the same surface for both runners; only the transport
differs (Llm: direct function-calling; Acp: via MCP).

### Fit note

ACP is coding-agent-centric (fs/terminal callbacks, "autonomously modify code").
For non-coding task agents the `Llm` runner (a) is more natural; for driving
coding agents the `Acp` runner (b) is the standard path.

## 6.5 Collaboration shapes — runners over a shared substrate

`Llm` and `Acp` are the two *primitive* runners (one model / one external agent). The
multi-agent collaboration patterns are **also just runners**, built on a shared substrate
`jet_backend`: resolve a member spec to a concrete backend (`{:ollama, model}` |
`{:acp, command}`), run it on role + input, return text. So every shape is "a runner module
+ one `dispatch/4` case", and they all inherit, for free:

- members run as **monitored BEAM processes** — crash-isolated (one member errors → a
  `failed` slot, the rest still deliver);
- output **streams** (each emits `{:text}`/`{:thought}`/`{:tool_call}`/`{:plan}` via the
  same `:__acp_stream__`), and a long sub-process forwards its tool_calls namespaced;
- each is **ACP-servable** (`jet acp-serve`) *and* directly callable (`spawn().m().await()`);
- the backend is the **user's choice** — `model:` (any Ollama model) or `drives:` (any ACP
  agent: claude-code-acp, codex, gemini); no model/vendor is assumed (a shape configured
  with neither raises `jet_backend::no_backend`).

| runner | topology | module |
|---|---|---|
| `Fleet` | star · parallel (mixture-of-agents) | `jet_fleet` (+ `workspace: :worktree` = parallel codegen) |
| `Pipeline` | chain (prompt-chaining / SOP) | `jet_pipeline` |
| `Refine` | loop (evaluator-optimizer) | `jet_refine` |
| `Debate` | mesh (multi-agent debate) | `jet_debate` |
| `Auto` | runtime shape selection (router) | `jet_auto` |
| `Architect` | runtime team generation (MetaGen-style) | `jet_architect` |
| `Flow` | runtime dataflow-graph generation | `jet_flow` |
| `Goal` | self-verifying loop until acceptance | `jet_goal` |

`Auto`/`Architect`/`Flow` decide the topology **at runtime** (the MetaGen/Maestro
direction — LLM-driven, not RL-trained); on the BEAM each generated node is supervised, so a
hallucinated/crashing node is isolated, not fatal — a blind spot of the LLM-multi-agent
literature. `Goal` closes the loop the *"/goal"* feature popularized: a cheap checker gates
each round on a machine-checkable `accept:` condition (overridable from the prompt with
`… Accept: <condition>`). Shape RUNNERS are kept **domain-neutral** (structure only — the
deliverable is code, a document, or a decision per the task); shared routing ("a new request
vs chitchat / a refinement?") lives in `jet_backend::is_substantive_request?`, used by
Fleet/Flow/Architect alike.

## 6.6 Dynamic model selection — static, escalate, or route (shared)

A shape's per-role backend need not be fixed. Give a role a tier-ordered **`models:` pool**
(the available models — the user's choice — each `{name, tier, ...}`) plus a **`select:`** mode,
and `jet_backend` decides which model to actually use:

| `select:` | mechanism | when |
|---|---|---|
| `:static` (default) | one backend (`model:` / `drives:`) | a known, single task |
| `:escalate` | round N uses the Nth pool model; a failed acceptance check escalates the next attempt to a stronger model (cheap-first cascade, FrugalGPT-style) | cost + reliability on a retry loop |
| `:route` | a cheap router picks the single best-fit model ONCE per task | heterogeneous tasks / specialised models |

Shared API (so any iterative shape gets all three for free):
- `jet_backend::resolve_pool(opts)` → `{:escalate, doers}` \| `{:route, doers}` \| `:static`
  (each doer = `{backend, label, profile}`).
- `jet_backend::at(doers, n)` → the Nth doer, clamped to the last (used by `:escalate` per round).
- `jet_backend::route_pick(opts, doers, task)` → the routed doer (used by `:route`).
- `jet_acp::round_note(round, label, total)` → surfaces "Round N: &lt;tier&gt; (model)".

**Routing is by FIT, not just cost.** `route_pick` shows the router each model's full *profile* —
`pool_profile` renders **every** metadata key except `:name` (`{tier, lang, good_at, context,
tools, …}`) — and the router matches the task's needs (domain, language, length, tool use) to the
models' stated capabilities, preferring the cheapest adequate one. The keys are **not hardcoded**:
whatever the user writes on a pool entry is weighed; the shape stays neutral. The router defaults
to the cheapest pool model; `router:` overrides it.

Two consumers today — Goal (the **doer** escalates/routes) and Refine (the **worker** does) — both
via the same `resolve_pool`/`at`/`route_pick`; a third iterative shape adds it in ~3 lines. This
exploits the doer/checker asymmetry (§ 6.5 Goal): the heavy DOER is escalated/routed while a cheap
CHECKER gates each round. Backends stay the user's choice — no model is assumed anywhere.

## 7. Why existing Jet constructs already fit

| existing | role in `agent` |
|---|---|
| `expose` (ExposedMethod in AST) | add `-> schema` = typed request/response contract |
| `peers` (PeerDef in AST) | the agent's **tools** (agent/tool graph = peer graph) |
| unified actor state (gen_server state) | conversation **Thread / memory / runner_state**; `sys:get_state` can inspect an agent's conversation |
| async / cast / Future (Kernel) | async-by-default calls + `.stream{}` |
| supervisors | restart/backoff for flaky LLM/subprocess agents — the real edge over Python frameworks |

## 8. The one genuinely new surface: schema literals

Jet is dynamically typed, so the return schema is a value, not a static type.
Minimal set: `String | Int | Float | Bool | [T] | {k: T, ...} | T?  | enum(:a, :b)`.
Runners convert it to (1) JSON Schema for LLM structured output / tool defs and
(2) a validator for the returned value.

## 9. Compiler vs library

- **Compiler (thin):** `agent ... end` block; `runner` / `role` / `tools`
  declarations; `expose -> schema` (schema literal parsing); desugar to
  actor + runner-dispatch; async-by-default call convention.
- **Library/runtime (thick, fast-moving):** `Llm` / `Acp` runners, MCP client,
  JSON-RPC, subprocess + sandbox management, schema validation, streaming.

## 10. Decisions (defaults; overridable)

1. Methods = requests; `tools` = LLM-callable. **Hybrid.**
2. **Stateful** conversation (Thread = actor state); per-method `fresh` opt-out.
3. **Async by default** (Future; `.await` / `.stream`).
4. Default runner = `Llm`; `Acp` is the standard (b) backend.
5. Schema literal = the minimal set in §8.

## 11. Standards landscape (layers, not competitors)

- **MCP** — agent ↔ tools/context (Anthropic; most adopted). Used by both runners.
- **ACP** — client ↔ agent / drive-an-agent (e.g. editors, over ACP). The `Acp` runner.
- **A2A** — agent ↔ agent (Google). Future: expose Jet agents as A2A peers.

A Jet `agent` can therefore use MCP tools, be driven by / drive ACP agents, and
peer via A2A — a node in the standard agent-interop graph.

## 12. Implementation status (branch `agent`)

Built and verified end-to-end, including against **real `claude-code-acp`**:

- `agent` desugars to actor + runner; `runner` / `role` / `tools` / `expose -> schema`
- async-by-default calls (`Future`) with `.await()` and `.stream do |chunk| … end`
- schema validation + JSON coercion of agent output to typed atom-keyed values
- **`Acp` runner** (stdio ndjson JSON-RPC): persistent connection = **session reuse**
  (conversation memory across turns), streaming, `fs/read|write_text_file` +
  `terminal/*` callbacks (basic fs sandbox via `within_sandbox?`), permission via
  an `on_approval(req)` hook (default allow)
- **`Llm` runner**: in-process Anthropic-API turn (needs an API key)

Live checks against claude-code-acp: turn 2 recalled turn 1 ("42"); streamed
chunks (Red/Blue/Yellow); structured output `{summary, words}`; a file written
through the fs callback.

Remaining follow-ups:

- symlink-tight fs sandbox + async/streaming `terminal/*`
- tool-use loop / MCP tools (esp. the `Llm` runner; `peers` as tools)
- conversation memory for the `Llm` runner; runner-level retry on schema mismatch
- A2A (expose Jet agents as peers); ConnectRPC stubs from `expose`
