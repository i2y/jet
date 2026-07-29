**English** | [日本語](README.ja.md)

<img src="https://github.com/i2y/jet/raw/master/jet_logo.png" width="300px"/>

# An agent is a file

```jet
# sage.jet
module sage
  agent Sage
    model "ollama:qwen3.6:35b-a3b"      # a real local model — no API key
    role "You research rigorously and cite sources."
    expose answer(question) -> {answer: String, sources: [String]?}
  end
end
```

```sh
jet acp-serve sage::Sage::answer sage.jet
```

That file is now an agent **inside your editor**: any [ACP](https://agentclientprotocol.com) client drives it, replies stream token by token, the session remembers, and plans and tool calls render natively. Swap the command for `jet mcp-serve` and the same file is an **[MCP](#mcp-both-directions) server** instead — tools, resources and prompts, all of them the agent. Add a `catalog/0` and drop the file in `console/agents/` and it appears in a **[web UI](#or-in-a-web-ui-jet-console)** too, recompiled and hot-loaded when you save.

**You don't rewrite your system in Jet.** The unit of adoption is one file — the same unit as a config file, with a compiler and a supervisor behind it.

What that file gets you, that a wrapper around a chat API doesn't:

- **It's supervised.** Crash it and OTP restarts it. Run ten thousand of them.
- **It survives machines.** Split a fleet across BEAM nodes, kill a whole node mid-flight, and the supervisor re-homes its agents onto the survivor.
- **It can drive other coding agents.** `drives "claude-code-acp"` — or `drives "claude"`, no adapter — makes Claude Code or Codex a *member* of a supervised Jet fleet.
- **Its declared schema can't be silently broken.** `-> {answer: String, sources: [String]?}` is a [contract](#the-schema-is-a-contract--schema-aligned-parsing), not a hint.

![Jet — object = actor = agent, with supervised crash-recovery](jet_demo.gif)

## Crash 2,000 agents. Kill a node.

…and the same model scales: **10,000 supervised agents**, crash 2,000 at random, the fleet stays intact — only the dead ones restart, the rest never notice.

![10,000 supervised agents, crash-isolated](fleet.gif)

…and the fleet spans **machines**: split the same supervised fleet across two BEAM nodes, kill the *whole worker node* mid-flight, and the supervisor re-homes its agents onto the survivor. No k8s, no queue, no sidecar — Erlang distribution + monitors, driven from Jet.

![a fleet spanning two nodes heals a whole-node kill](fleet_dist.gif)

The LLM `Fleet` runner does the same: `nodes: ["b@host"], retry: 2` places members across nodes and respawns lost ones on survivors — see [docs/features.md](docs/features.md).

Runnable: [`examples/pitch.jet`](examples/pitch.jet) (the first GIF) · [`examples/fleet.jet`](examples/fleet.jet) (the fleet) · [`examples/fleet_dist.jet`](examples/fleet_dist.jet) (two nodes, self-healing).

More on driving these [from your editor](#agents-in-your-editor-over-acp) and in [Jet Console](#or-in-a-web-ui-jet-console).

## `object = actor = agent`

That file is small because the agent is a *form* in the language, not a library on top of one. One object model and one call syntax — `x.method()` — spans a local value → a concurrent process → a supervised AI agent:

```ruby
class Point                                    # a plain value
  def dist()  math::sqrt(@x * @x + @y * @y)  end
end

agent Sage                                     # an AI agent — same x.method() call
  model "ollama:qwen3.6:35b-a3b"                # a real local LLM (no API key)
  expose answer(q) -> {answer: String}          # native, schema-typed output
end

actor Worker                                   # an agent is just a supervised process
  def add(n)  @total = @total + n  @total  end
  def on_message(_)  erlang::error(:boom)  end   # crash it — the supervisor restarts it
end
```

AI agents are long-lived, stateful, concurrent and failure-prone — exactly what the BEAM has handled since 1986. Which raises the fair question:

## Why a language, and not an Elixir library?

The honest version of this argument, since the flattering one doesn't survive contact with anyone who knows Elixir.

**Elixir could do most of this.** Protocols already dispatch on the first argument, so one call can be uniform across a struct and a PID. Macros could generate the `agent` form, the gen_server behind it, the state threading, the futures — and macros run at compile time, so they could even emit the warnings. Nearly every feature below is expressible as a library, and the missing `x.method()` is notation, not capability.

What a library cannot do is **stop you**.

In a library every safeguard is a function you may call, and the underlying primitive stays one keystroke away. In a language it can be the only path there is. That is the difference between a convention and a guarantee:

| | as a library | in Jet |
|---|---|---|
| a declared `-> Type` | validated if you remember to call the validator | every runner and every shape funnels through [one parser](#the-schema-is-a-contract--schema-aligned-parsing); the `agent` surface has no path around it |
| a reply that can't satisfy the schema | whatever the caller wrote — often the raw text, failing far from its cause | `{:error, {:schema_mismatch, …}}`, naming the field, at the cause |
| a mistyped runner name | your dispatch's fallback, if it has one | an error listing the known runners — never fabricated data |
| a mistyped type name or option key | a runtime surprise, or nothing at all | rejected at compile time, or before the turn runs |
| a `match` missing an enum value | found in production | a compiler warning naming the value |

None of that is clever. It is simply **not optional** — and *not optional* is the one thing a language sells that a library can't.

The notation follows from that decision rather than justifying it: once the agent is a first-class form, `x.method()` spanning a value, a process and an agent is just what the object model already looks like. [`expose`](#agents) is literally the same keyword for an `actor` and an `agent`; the return type is the only difference.

**Why not Gleam,** then, given Jet's own compiler is written in it? Gleam has no macros, by design — so the `agent` form couldn't be a library there even in principle. And a static type can't promise what an LLM returns, nor describe a topology that [`Architect` and `Flow`](#collaboration-shapes--swap-the-topology-keep-the-interface) *generate at runtime*. Jet is dynamically typed on purpose, and pays for it with [targeted checks](#what-the-compiler-checks--without-a-type-system) over the parts that are declared and closed.

## Agents

The `agent` keyword backs an object with an LLM/agent runtime — `object = actor = agent`, one call syntax from local values to AI agents. An `agent` desugars to an [`actor`](#actors) plus a pluggable **runner**; calls are **async** (they return a `Future` — `.await()` / `.stream do |ev|`). An agent declares its interface with `expose`, exactly as an actor does — the **return type** is what decides how the turn comes back:

```ruby
# a thinking machine: expose a TYPED answer
agent Researcher
  model "claude-opus-4-8"                   # in-process LLM runner
  role "You research rigorously and cite sources."

  expose research(question) -> {answer: String, sources: [String]}
  tool web_search                           # peers / agents / MCP it can call
end

r = Researcher.spawn()
r.research("What is the BEAM?").await()     # => {:ok, {answer: ..., sources: [...]}}
```

```ruby
# an external coding agent: expose WORK, get a TurnResult
agent Coder
  drives "claude-code-acp"                  # drive an external agent over ACP
  role "Test-driven. Minimal diffs."
  workspace "./src"                         # fs sandbox root

  expose fix(description) -> TurnResult     # .text / .ok? / .edits / .plan / ...

  def on_approval(req)                      # permission policy for the agent
    match req.get(:kind)
      case "execute"
        :deny
      case _
        :allow
    end
  end
end

Coder.spawn().fix("make the failing test pass").stream do |ev|   # watch it work
  match ev
    case {:plan, steps}
      io::format("plan: ~p~n", [steps])
    case {:tool_call, t}
      io::format("-> ~ts~n", [t.get(:title)])
    case {:text, s}
      io::format("~ts", [s])
    case _
      :ok
  end
end
```

- **`expose m(args)`** — the one declaration form, shared with `actor`. The return type decides the delivery, so there is no second keyword to learn:
  - no `->` — free text.
  - **`-> Type`** — a typed answer. The schema is a **contract**, not a hint: see [below](#the-schema-is-a-contract--schema-aligned-parsing).
  - **`-> TurnResult`** — the *work* the agent did (`.text` / `.ok?` / `.edits` / `.commands` / `.plan` / `.files` / `.tool_calls`), not a coerced schema.
  - (`ask m(...)` and `task m(...)` are the older spellings, still accepted.)
- **`runner X(...)`** is the one backend form. **`model X`** and **`drives "cmd"`** are shorthands for `runner Llm(model: X)` and `runner Acp(command: "cmd")` — an in-process LLM turn, or an external [ACP](https://agentclientprotocol.com) agent (Claude Code via `claude-code-acp`, Codex via `npx @zed-industries/codex-acp`, …), or `drives "claude"` to drive the Claude Code CLI **directly**, no adapter. Sessions persist (memory), output streams, fs/terminal are sandboxed. Every collaboration shape and `Fake` are the same form.
- **`tool …`** — other agents / functions / MCP servers the agent can call. An optional `, :kind` (`:execute` / `:read` / `:edit` / `:fetch` / …) says what it *does*, which is what `on_approval` gates on; undeclared reads as `"other"` rather than guessing.
- **`def on_approval(req)`** — gate the agent's permission requests (`:allow` / `:deny`); the same `on_*` callback convention as `on_terminate` / `on_message`. One policy covers both an external ACP agent's request and a native tool call — both are shaped by `jet_policy::request`, so `req.get(:kind)` reads the same either way.
- **`.stream do |ev|`** — structured turn events: `{:text, _}` `{:thought, _}` `{:tool_call, _}` `{:plan, _}` `{:usage, _}` `{:prompt, _}`. `{:prompt, …}` carries the **request as actually sent** (`system` / `input` / `model`), for every runner and every shape member — so iterating on a prompt means reading it, not inferring it.

See [`docs/agent_design.md`](docs/agent_design.md) and the [ACP protocol sequences](docs/acp_sequence.md).
Want to run an agent right now with no API key? [**Agents in your editor**](#agents-in-your-editor-over-acp) drives these from your editor on a local LLM (Ollama).

### The schema is a contract — Schema-Aligned Parsing

A model told to reply with only JSON will still wrap it in a markdown fence,
think out loud first, quote with `'`, drop a comma, or type a number as a string.
Jet does not ask it to try again — a retry costs a round trip and usually
reproduces the same output. It repairs the reply *against the declared schema*.

```jet
expose research(question) -> {answer: String, sources: [String], confidence: Int}
```

| the model actually sent | you get |
|---|---|
| a fenced block, prose around it, or `<think>…</think>` first | the value |
| `{answer: 'hi', sources: 'one', confidence: '85',}` | `{answer: "hi", sources: ["one"], confidence: 85}` |
| `{"sourceList": [...]}` where `source_list:` was declared | matched |
| `{"answer": "hi"}` — `sources` absent | `{:error, {:schema_mismatch, …}}` naming `value.sources`, with the partial value |

Two properties make it a contract rather than a best effort. Every repair is
**licensed by the declared type** — a lone string becomes a one-element list only
because the schema says `[String]`, never because it looked convenient. And every
repair is **priced**: among all the readings of one reply the cheapest wins, and
having the data outranks any pile of small fixes, so an object missing a field
never loses to prose that matched nothing.

A schema that still cannot be satisfied **fails at its cause**, instead of
handing your code a binary that crashes three call frames later.

This runs on every runner and every shape — [`src/jet_sap.jet`](src/jet_sap.jet),
ported from the design of [BAML](https://boundaryml.com/blog/schema-aligned-parsing)'s
reference implementation. Its test suite is the list of things models actually do:
`./jet -r jet_sap::run_tests src/jet_sap.jet`.

A schema type is `String` · `Int` · `Float` · `Bool` · `Atom` · `[T]` · `{k: T}` ·
**`enum(:a, :b, :c)`**, and a field may carry two modifiers:

```jet
expose research(q) -> {answer:    String   "one sentence, no preamble",
                       sources:  [String]? "URLs only, no titles",
                       certainty: Int?}
```

An **enum** is a *closed set*, which is where matching a model's answer pays off
most: `stale`, `"current"`, `UNRELATED` and `I'd say stale.` all land on the right
value, while `stale or current` is **reported as ambiguous rather than guessed**.

**`?`** is not cosmetic — it changes the price. A missing *required* field costs
100 in the score above; a missing *optional* one costs 1. That gap is the whole
meaning of the mark: "the model legitimately left this out" stops being the same
event as "this is the wrong answer". `null` counts as absent.

The **description** travels with the declaration and is written once: the model
sees `"string // URLs only, no titles"` in the compact prompt schema, and a
backend that constrains generation gets it as JSON Schema's own `description`.
Runnable: [`examples/agent_optional_schema.jet`](examples/agent_optional_schema.jet).

### What the compiler checks — without a type system

Dynamic typing is the right choice here: no type system can promise what an LLM
returns, the BEAM's mailbox is untyped, and `Architect`/`Flow` *generate their
topology at runtime*, which a static type could not express. But some things are
declared, closed, and already in the AST — so they are checked, and the cost of
getting them wrong is an error at the mistake rather than plausible nonsense:

| you write | what used to happen | what happens now |
|---|---|---|
| `-> {answer: Strng}` | the typo became an atom that conformed to **everything** | parse error naming the valid types |
| `runner Fleeet(...)` | fell through to the stub runner, which **synthesizes** a schema-conforming value — a typo returned fabricated data that looked like success | `{:error, {:unknown_runner, …}}` listing the known runners |
| `runner Fleet(member: …)` | an empty fleet, silently | `{:error, {:unknown_runner_options, …}}` — checked against each shape's own manifest, so shapes stay library-level |
| a `match` missing an enum value | a runtime `badmatch`, eventually | a compile-time warning naming the value you forgot |

The exhaustiveness check connects `a = Agent.spawn()` and a `match a.method(…)` in
the same function body; across function boundaries it stops, because in a dynamic
language nothing says what a parameter holds. It is a warning, never an error.

The **declaration** can live anywhere in the project, though: `jet build src/`
parses every file before compiling any, so an `expose … -> enum(...)` in one
module is checked against a `match` written in another. That is the case a macro
cannot reach — Elixir compiles module by module, and a macro only ever sees its
own expansion, so the two are never in view together.

Runnable: [`examples/agent_enum_check.jet`](examples/agent_enum_check.jet) (one
module) · [`examples/enum_xmodule/`](examples/enum_xmodule) (two).

For an Ollama backend the schema can reach the model two ways —
`runner Llm(structured: :constrained)` (the default: a JSON Schema compiled to a
sampling grammar, so the shape is guaranteed) or `structured: :prompt` (the compact
schema in the prompt, repaired by `jet_sap`). Which wins is per-model and worth
measuring on *your* model rather than inheriting someone's benchmark:
[`examples/sap_structured_ab.jet`](examples/sap_structured_ab.jet) runs both arms
over the same tasks and reports schema-conformance, answer-correctness and latency.

### Testing an agent — no model, no key, no network

````jet
agent Researcher
  runner Fake(replies: "Sure!\n```json\n{\"answer\": \"42\"}\n```")
  expose research(question) -> {answer: String}
end
````

`Fake` answers with canned text, and that text goes through the *same* parse a
real reply does — so a test pins down what your program gets when a model is
messy, not what a mock was told to return. `replies:` takes a value, a
`{method: reply}` map, or a `fn(method, args)`.

[`examples/agent_fake_test.jet`](examples/agent_fake_test.jet) runs three agents:
markdown-wrapped, five-defects-in-one-turn, and a missing field that correctly fails.

## Collaboration shapes — swap the topology, keep the interface

The `Fleet` that healed the node-kill above is one *shape*. **Shapes are a standard library, not language features**: two primitive runners (`Acp`, `Llm`) — plus `Fake` for tests — and nine collaboration shapes, each just "a runner module + one dispatch line" over a shared substrate (`jet_backend`: resolve a member to `{:ollama, model}` | `{:acp, command}`, run it, return text). Behind the same `agent` + `expose`, the **runner** picks *how* a turn is run — so every shape inherits the same things for free: members run as **monitored BEAM processes** (crash-isolated — kill one, the rest still deliver), output **streams**, and each is **ACP-servable** (drive it from an ACP client) *and* usable directly (`spawn().m().await()`). A member is a local model (`model:`) or any external ACP agent (`drives:` — Claude Code, Codex, Gemini, …); the backend is the user's choice, never assumed.

| runner | topology | what it does |
|---|---|---|
| `Acp` | one external agent | drive `claude-code-acp` / `codex` / `gemini` over ACP |
| `Llm` | one in-process LLM | Jet runs the loop (Ollama native structured output, or a hosted provider) |
| `Fleet` | star · parallel | N members analyze one topic in parallel; a lead synthesizes (mixture-of-agents) |
| `Pipeline` | chain | sequential stages, each transforming the last (`implement → test → review`) |
| `Refine` | loop | a worker drafts, a critic reviews, repeat until approved (evaluator-optimizer) |
| `Debate` | mesh | members argue opposing sides over rounds; a judge concludes |
| `Auto` | router | a router picks the best shape from a menu at runtime |
| `Architect` | self-generating | a designer writes the team (shape + roles) for *this* task, then runs it |
| `Flow` | generated DAG | a designer generates a dataflow graph of agents; independent nodes run in parallel |
| `Goal` | verify-loop | keep attempting until a machine-checkable `accept:` condition is verifiably met |
| `Plan` | plan → execute | a planner decomposes the goal into steps and executes them in order, re-planning when a step yields nothing; `via:` runs each step through a sub-shape |

```ruby
# Pipeline — sequential stages, each building on the last
runner Pipeline(drives: "claude-code-acp", stages: [
  {name: "Implement", role: "Write the code."},
  {name: "Test",      role: "Build and test it; show the output."},
  {name: "Review",    role: "Review quality and security."}])

# Debate — opposing sides + a judge
runner Debate(model: "ollama:qwen3.6:35b-a3b", rounds: 2,
  agents: [{name: "For",     role: "Argue in favor."},
           {name: "Against", role: "Argue against."}],
  judge: {role: "Weigh both sides and decide."})

# Architect — it designs the team (shape + roles) for the task, then runs it
runner Architect(drives: "claude-code-acp")

# Flow — it generates a dataflow graph; independent nodes run in parallel on the BEAM
runner Flow(drives: "claude-code-acp")

# Goal — keep going until the acceptance condition is verifiably met (the "/goal" idea)
runner Goal(drives: "claude-code-acp",
            accept: "go build ./... and go test ./... pass, shown with the real output")
```

The meta-orchestrators (`Auto`, `Architect`) and the graph generator (`Flow`) decide the
**topology at runtime** — the MetaGen/Maestro direction, but here LLM-driven and, on the
BEAM, **supervised**: a hallucinated node that crashes is isolated, not fatal. `Goal` closes
the loop the *"/goal"* feature popularized — a cheap checker gates each round on a
machine-checkable condition (which can also arrive from the prompt: `… Accept: <condition>`).
`Codegen` is `Fleet` with `workspace: :worktree`: N agents implement the *same* task in
their own git worktrees, then the lead picks the best diff.

**Cost-aware model selection** is built in. Instead of one `model:`, give an iterative shape
(`Goal`, `Refine`) a tier-ordered `models:` pool plus a `select:` mode — `:escalate` (try the
cheap model first; move up to a stronger one only when a check rejects the result) or `:route`
(a cheap router reads each model's profile and picks the best fit per task). The pool is your
choice of Ollama models and/or ACP agents — so the big model runs only when it's worth it.
→ [escalate](examples/acp_goal_escalate_demo.jet) · [route](examples/acp_goal_route_demo.jet)

![Flow — a generated dataflow graph: the designer composes the topology, independent nodes run in parallel, a sink combines them](flow.gif)

![Goal — a self-verifying loop: attempt → a cheap checker gates on the acceptance condition → repeat until met](goal.gif)

Runnable: [Pipeline](examples/acp_pipeline_demo.jet) · [Refine](examples/acp_refine_demo.jet) ·
[Debate](examples/acp_debate_demo.jet) · [Auto](examples/acp_auto_demo.jet) ·
[Architect](examples/acp_architect_demo.jet) · [Flow](examples/acp_flow_demo.jet) ·
[Goal](examples/acp_goal_demo.jet) · [Plan](examples/agent_planner_demo.jet) · [Codegen](examples/acp_codegen_demo.jet).

**Add your own shape** — a `turn/4` module + one `dispatch/4` case (the `runner Name(...)` DSL
resolves the name generically, so no parser change): see
[Adding your own shape](docs/agent_design.md#67-adding-your-own-shape).

### MCP, both directions

Jet speaks **MCP** as fully as it speaks ACP, in both directions.

As a **server**, `jet mcp-serve Module::Agent::method file.jet` puts the whole agent
behind stdio JSON-RPC, and all three MCP primitives are the agent:

| MCP | is |
| --- | --- |
| `tools` | its `expose`d methods (one tool each) **and** its `tool` declarations |
| `resources` | `jet://agent/role`, `jet://agent/manifest`, `jet://memory/conversation`, `jet://memory/facts` |
| `prompts` | its `skills` |

A `tools/call` runs in its own process, so `ping` and a second call stay live while it
works; with a `_meta.progressToken` the turn streams back as `notifications/progress`;
`notifications/cancelled` ends the turn **without killing the agent**. A declared
`-> Type` comes back as `structuredContent` as well as text. The served agent can call
*back* into the client — `jet_mcp::roots`, `jet_mcp::sample` (borrow the client's model),
`jet_mcp::elicit`. See [`examples/mcp_server_demo.jet`](examples/mcp_server_demo.jet).

As a **client**, an agent **consumes** external MCP servers it declares with `mcp "…"` —
their tools become callable mid-turn
([`examples/agent_mcp_demo.jet`](examples/agent_mcp_demo.jet)). The connection is
bidirectional, like the ACP one: the server's `ping` / `roots/list` /
`sampling/createMessage` are **answered** (sampling runs on the agent's own backend),
and its progress and log notifications land on the same event bus as everything else.
`resources/*` and `prompts/*` are available too, not just tools. A server declared on an
agent with an `Acp` runner is passed through to the external agent as well.

Both halves are tested against each other, with no model, key or network:
[`examples/test_mcp_client.jet`](examples/test_mcp_client.jet).

### OpenTelemetry

Set an endpoint and every turn becomes a trace — no code change, and nothing to
configure per agent:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 ./jet -r App::run app.jet
```

```
jet.agent.turn                       ← one root span per turn, with the turn's token totals
└─ 🏗 Fleet · team of 2               ← every shape node, nested by its real parent
   ├─ 👤 Researcher
   │  └─ gen_ai.usage qwen3.6         ← gen_ai.usage.input_tokens / .output_tokens
   └─ 👤 Critic                       ← status code 2: this member failed
```

The runtime already built that tree to draw the Console's execution view;
[`jet_otel`](src/jet_otel.jet) is the one place that exports it as OTLP/HTTP JSON —
so shapes, runners and examples needed no changes to become observable. Backend calls
and tool calls carry the `gen_ai.*` semantic conventions, W3C `traceparent` goes out on
provider HTTP, and export runs in a batching background process, so telemetry never
slows a turn. Standard configuration (`OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_SERVICE_NAME`,
`OTEL_SDK_DISABLED`); **off, at zero cost, until an endpoint is set**. Runnable:
[`examples/test_otel.jet`](examples/test_otel.jet).

## Agents in your editor (over ACP)

The same `agent` runs inside a real editor. `jet acp-serve Module::Agent::method file.jet`
exposes it over the [Agent Client Protocol](https://agentclientprotocol.com), so any
ACP client drives it: replies stream
token-by-token, the session remembers, and plans / tool calls render natively.
Three agents, escalating from a one-liner to a supervised fleet:

**1. Hello, agent** — a real local LLM, streamed, with conversation memory.

```ruby
agent Sage
  model "ollama:qwen3.6:35b-a3b"           # a real local LLM, no API key
  role "You are a helpful assistant. Be concise."
  expose reply(message)                    # free-text answer, streamed
end
```

**2. A real agent** — it answers about a file without touching disk: it asks *your
editor* to read it, mid-turn, over the same ACP connection.

```ruby
agent Reader
  model "ollama:qwen3.6:35b-a3b"
  role "Call read_file with the path you're given, then answer strictly from its contents."
  expose describe(request)
  tool read_file(path: String) do |p|
    match jet_acp_server::read_file(p)      # agent -> client request, mid-turn
      case {:ok, res}
        maps::get(<<"content">>, res, <<"(empty)">>)
      case _
        "could not read it"
    end
  end
end
```

**3. A supervised fleet** — one ACP agent, behind it N sub-agents that run in
**parallel**, each its own BEAM process with its own lens. They're monitored and
crash-isolated: kill one and the rest still deliver. A lead agent then synthesizes
their notes into one conclusion — *map + reduce* across a supervised fleet.

```ruby
agent Panel
  runner Fleet(model: "ollama:qwen3.6:35b-a3b", members: [   # the fleet's LLM (a member may override)
    {name: "Risks",   role: "Name the biggest risks."},
    {name: "Upside",  role: "Name the biggest benefits."},
    {name: "Skeptic", role: "Say why it might fail."}])
  expose review(topic)
end
```

The runnable example adds a 4th member rigged to crash — the GIF below shows it
isolated (`failed`) while the other three still deliver.

![Panel — a supervised BEAM fleet behind one ACP agent: parallel, crash-isolated, map + reduce](panel.gif)

Drive it from a terminal, or point your ACP client at it:

```sh
# ndjson JSON-RPC over stdio — ACP clients speak this; so can a script
jet acp-serve acp_fleet_demo::Panel::review examples/acp_fleet_demo.jet
```

```jsonc
// Example: an editor's ACP agent-server config (here, Zed's ~/.config/zed/settings.json) —
// then pick "Jet Panel" in the Agent Panel. (PATH is pinned because a GUI-launched editor may
// lack Homebrew on PATH; jet is an escript.)
"agent_servers": {
  "Jet Panel": {
    "type": "custom",
    "command": "/abs/path/to/jet",
    "args": ["acp-serve", "acp_fleet_demo::Panel::review", "/abs/path/to/examples/acp_fleet_demo.jet"],
    "env": { "PATH": "/opt/homebrew/bin:/usr/bin:/bin" }
  }
}
```

Runnable: [`examples/acp_demo.jet`](examples/acp_demo.jet) ·
[`examples/acp_fs_demo.jet`](examples/acp_fs_demo.jet) ·
[`examples/acp_fleet_demo.jet`](examples/acp_fleet_demo.jet).

## …or in a web UI (Jet Console)

The same agents run in **[Jet Console](console/)** — a Phoenix LiveView web app, pure BEAM
(**no Node, no Electron**): projects, **parallel** threads, a markdown conversation, an embedded
terminal, and a live plan + tool-activity panel. Pick a backend per thread (a local model, any
ACP agent, **or** the Claude Code CLI driven directly), build agents with a no-code form, and
isolate a thread in its own git worktree.

![Jet Console — a Forge agent on the native Claude CLI driving a Pipeline team, with the live plan + tool-activity panel on the right, a markdown conversation, and a clean project/thread sidebar](docs/img/console-hero.png)

**No install.** A self-contained binary for each OS is committed in the repo — ERTS, the app and
the Jet stdlib bundled by [Burrito](https://github.com/burrito-elixir/burrito). No Elixir, no
Erlang, no Node, and no environment variables: it generates and persists its own secret on first
run.

```sh
./console/burrito_out/jc_macos start     # jc_linux · jc_windows.exe → http://localhost:4000
```

Or from source, if you have Elixir:

```sh
cd console && mix setup && mix phx.server   # → http://localhost:4000
```

More screenshots — the [parallel-threads board, the no-code agent builder, the file viewer, and the terminal](console/README.md#screenshots). Building the binaries yourself: [`console/README.md`](console/README.md#single-binary-per-os-burrito).

## Language Features

### Types

```ruby
# Numbers
49        # integer
4.9       # float

# Booleans
true
false

# Atoms
:foo

# Lists
list = [2, 3, 4]
[1, *list]             # => [1, 2, 3, 4]
[head, *rest] = list   # head => 2, rest => [3, 4]

# Tuples
{1, 2, 3}

# Maps
dict = {name: "jet", version: 2}
dict.get(:name, "?")  # => "jet"

# Strings (charlists)
"Hello"

# Binaries
<<1, 2, 3>>
<<"abc">>

# Anonymous functions
add = {|x, y| x + y}
add.(3, 4)  # => 7

multiply = do |x, y|
  x * y
end
```

### Variable Rebinding

```ruby
# x = x + 1 just works — the compiler generates fresh BEAM variables
total = 0
total = total + 10
total = total + 20
total  # => 30
```

### Classes & Immutable State

`@attr` reads and writes instance state. Each mutation returns a new object — the original is unchanged. The compiler automatically returns `self` at the end of `initialize`.

```ruby
# Point.jet — standalone class (no module wrapper needed)
class Point
  def initialize(x, y)
    @x = x
    @y = y
  end

  def move(dx, dy)
    @x = @x + dx
    @y = @y + dy
    self
  end

  def x()  @x  end
  def y()  @y  end
end

p = Point.new(0, 0)
p2 = p.move(3, 4)
# p is unchanged — each mutation returns a new object
```

### Mixins — Composition over Inheritance

```ruby
class Stack
  include Enumerable

  def initialize()
    @items = []
  end

  def push(item)
    @items = [item, *@items]
    self
  end

  def reduce(acc, func)
    lists::foldl({|item, a| func.(a, item)}, acc, @items)
  end
end

s = Stack.new().push(10).push(20).push(30)
s.map {|n| n * 2}                 # => [60, 40, 20]
s.reduce(0) {|acc, n| acc + n}    # => 60
```

### Actors

The `actor` keyword creates a process-backed class (OTP gen_server). `expose` declares its public interface — the *same* keyword an [`agent`](#agents) uses, which is what makes `object = actor = agent` true at the syntax level and not just in the runtime; the only difference is that an agent's return type also picks how the turn comes back. Actor instance state *is* the gen_server's state — updated with the same `@attr` syntax as classes and threaded for you, so methods don't need to return `self`, and the live state is introspectable with `sys:get_state`.

```ruby
actor ChatRoom
  expose post(user, text), recent(n), count()

  def initialize(name)
    @name = name
    @messages = []
  end

  def post(user, text)
    @messages = [{user, text}, *@messages]
    :ok
  end

  def recent(n)
    lists::sublist(@messages, n)
  end

  def count()
    erlang::length(@messages)
  end

  def on_terminate(reason)
    puts("Room closing: ~p", [reason])
  end
end

room = ChatRoom.spawn("general")
room.post("alice", "Hello!")
room.count()  # => 1

# Async & cast
future = room.async().count()
future.await()        # => 1
room.cast().post("bob", "Fire and forget")

# Timers & raw messages
room ! {:custom, "message"}     # send raw message (handled by on_message)
send_after(1000, room, :ping)   # delayed message

# Monitoring
monitor(room)  # receive {:DOWN, ref, :process, pid, reason} on exit
```

### Effect Declarations (`needs` / `platform`)

```ruby
module Greeter
  needs Console

  def self.greet(name)
    Console::puts("Hello, " ++ name ++ "!")
  end
end

# Provide concrete implementations via platform blocks
platform Production
  provide Console with StandardConsole
end
```

### Pattern Matching

```ruby
match {x, y}
  case {0, 0}
    "origin"
  case {0, _}
    "on Y axis"
  case {x, y} if x == y
    "on diagonal"
  case _
    "somewhere else"
end
```

### Error Handling

`try` / `catch` / `finally` handle recoverable failures. The caught value is an exception map with `:class`, `:reason`, and `:stacktrace`. For ordinary expected failures, prefer `{:ok, _}` / `{:error, _}` tagged tuples with `match` — reserve `try` for wrapping code that raises, or for retry/cleanup.

```ruby
def safe_div(a, b)
  try
    {:ok, a / b}
  catch e
    {:error, e.get(:reason)}    # b == 0  =>  {:error, :badarith}
  finally
    puts("attempted")           # optional; runs on success and failure
  end
end

raise :boom                     # raise a value (compiles to erlang:error/1)
```

`finally` is optional, and a `try` may omit `catch` for plain cleanup (`try ... finally ... end`).

### Erlang Interop

```ruby
# Call any Erlang/OTP module with :: syntax
node = erlang::node()
timer::sleep(1000)
lists::sort([3, 1, 2])  # => [1, 2, 3]
```

There is no `import`. BEAM module names are global and resolved at run time, so a
qualified call is complete on its own — which is why Erlang needs no import
either. `alias` shortens the name without hiding it:

```ruby
alias jet_backend as B

B::to_bin(topic)        # reads jet_backend::to_bin(topic)
```

A pure rename at parse time: the call site stays **qualified**, so `B::` is still
visibly a remote call and one line at the top of the file says what it is. The
other half of `import` — pulling names in unqualified, so a reader can't tell a
local call from a remote one — is what Erlang's own `-import` is discouraged for,
and Jet doesn't offer it.

### Higher-Order Functions

```ruby
nums = [5, 3, 8, 1, 9]

nums.map {|n| n * 2}             # => [10, 6, 16, 2, 18]
nums.select {|n| n > 4}          # => [5, 8, 9]
nums.reduce(0) {|acc, n| acc + n}  # => 26

3.times do |i|
  puts("tick ~p", [i])
end
```

## Requirements

- Erlang/OTP >= 26.0
- Gleam >= 1.0

## Installation

```sh
$ git clone https://github.com/i2y/jet.git
$ cd jet
$ gleam build
$ gleam export erlang-shipment && escript build_escript.erl
$ ./jet --help
```

## Usage

### Compiling a single file

```sh
$ ./jet Foo.jet
```

### Compiling and executing

```sh
$ ./jet -r Foo::bar Foo.jet
```

### Serving an agent over ACP

Expose an `agent` to any [ACP](https://agentclientprotocol.com) client
over stdio — no serve boilerplate in the file:

```sh
$ ./jet acp-serve Module::Agent::method Foo.jet
```

See [Agents in your editor](#agents-in-your-editor-over-acp) for the demos and an example config.

### Serving an agent over MCP

The same agent, the same lack of boilerplate, for any [MCP](https://modelcontextprotocol.io) client.
Its exposed methods and its `tool`s become tools, its role/composition/memory become resources, and
its `skills` become prompts:

```sh
$ ./jet mcp-serve Module::Agent::method Foo.jet
```

See [MCP, both directions](#mcp-both-directions).

### Building a project

```sh
$ ./jet build src/
```

### Building an escript (standalone executable)

Bundle all `.beam` files into a single executable. Requires Erlang on the target machine.

```sh
$ ./jet escript MyApp src/
$ ./myapp
```

### Building an OTP release

Generate a release directory with `bin/` launcher and `ebin/` beams.

```sh
$ ./jet release MyApp src/
$ ./_release/bin/myapp
```

**Entry point convention:** `jet escript` and `jet release` call `Module::main()`. Define `def self.main()` in your app module.

### Running tests

```sh
$ gleam test                                               # the compiler: lexer, parser, codegen
$ ./jet -r jet_sap::run_tests src/jet_sap.jet              # Schema-Aligned Parsing
$ ./jet -r jet_architect::run_tests src/jet_architect.jet  # the Architect shape's guards
```

To test **your own** agents, give them the `Fake` runner: canned replies that still
go through the real schema parse, so no model, API key or network is involved —
see [Testing an agent](#testing-an-agent--no-model-no-key-no-network).

### Letting a coding agent write Jet

Jet is new, so it is essentially absent from every model's training data — and because it *looks*
like Ruby, an agent will confidently write Ruby-shaped code that doesn't compile. Copy the
[`jet-lang`](.agents/skills/jet-lang) Agent Skill into the project you're writing `.jet` files in:

```sh
$ mkdir -p .agents/skills && cp -R /path/to/jet/.agents/skills/jet-lang .agents/skills/
```

Inside a Jet checkout there is nothing to install — and since `jet_skills` scans that same
`.agents/skills`, a **Jet agent** can load it and write Jet too. Every factual claim it makes is
pinned by a probe (`.agents/skills/jet-lang/probes/run.sh`), because the compiler, not a document,
is the authority on what Jet accepts.

## Influences

Jet is a dynamically typed, OOP-functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Its syntax and object model are influenced by [Ruby](https://www.ruby-lang.org) and [Reia](https://github.com/tarcieri/reia).
