<img src="https://github.com/i2y/jet/raw/master/jet_logo.png" width="300px"/>

Jet is a dynamically typed, OOP-functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Its syntax and object model are influenced by [Ruby](https://www.ruby-lang.org) and [Reia](https://github.com/tarcieri/reia).

> **`object = actor = agent`** — one object model and one call syntax (`x.method()`) spanning a local value → a concurrent process → a supervised AI agent.

AI agents are long-lived, stateful, concurrent, and failure-prone — exactly what the BEAM has handled since 1986. Jet makes the **agent a first-class language primitive** on the runtime built for millions of supervised, fault-tolerant processes: crash an agent and OTP restarts it; run thousands as lightweight processes; drive external coding agents over [ACP](https://agentclientprotocol.com) and expose tools over MCP — in Ruby-like syntax.

```ruby
class Point                                    # a plain value
  def dist()  math::sqrt(@x * @x + @y * @y)  end
end

agent Sage                                     # an AI agent — same x.method() call
  model "ollama:qwen3.6:35b-a3b"                # a real local LLM (no API key)
  ask answer(q) -> {answer: String}             # native, schema-typed output
end

actor Worker                                   # an agent is just a supervised process
  def add(n)  @total = @total + n  @total  end
  def on_message(_)  erlang::error(:boom)  end   # crash it — the supervisor restarts it
end
```

![Jet — object = actor = agent, with supervised crash-recovery](jet_demo.gif)

…and the same model scales: **10,000 supervised agents**, crash 2,000 at random, the fleet stays intact — only the dead ones restart, the rest never notice.

![10,000 supervised agents, crash-isolated](fleet.gif)

Runnable: [`examples/pitch.jet`](examples/pitch.jet) (the first GIF) · [`examples/fleet.jet`](examples/fleet.jet) (the fleet).

And those agents run **inside your editor**: `jet acp-serve` exposes one over
[ACP](https://agentclientprotocol.com), so any ACP client drives it
(streaming, with memory), including a supervised, crash-isolated **fleet**.
→ [**Agents in your editor**](#agents-in-your-editor-over-acp)

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

The `actor` keyword creates a process-backed class (OTP gen_server). `expose` declares its public interface. Actor instance state *is* the gen_server's state — updated with the same `@attr` syntax as classes and threaded for you, so methods don't need to return `self`, and the live state is introspectable with `sys:get_state`.

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

### Agents

The `agent` keyword backs an object with an LLM/agent runtime — `object = actor = agent`, one call syntax from local values to AI agents. An `agent` desugars to an `actor` plus a pluggable **runner**; calls are **async** (they return a `Future` — `.await()` / `.stream do |ev|`). Methods come in two kinds, matching the two natural shapes of an agent result:

```ruby
# a thinking machine: ASK for a typed answer
agent Researcher
  model "claude-opus-4-8"                   # in-process LLM runner
  role "You research rigorously and cite sources."

  ask research(question) -> {answer: String, sources: [String]}
  tool web_search                           # peers / agents / MCP it can call
end

r = Researcher.spawn()
r.research("What is the BEAM?").await()     # => {:ok, {answer: ..., sources: [...]}}
```

```ruby
# an external coding agent: TASK it to do work, get a TurnResult
agent Coder
  drives "claude-code-acp"                  # drive an external agent over ACP
  role "Test-driven. Minimal diffs."
  workspace "./src"                         # fs sandbox root

  task fix(description)                     # -> TurnResult (.text/.ok?/.edits/.plan/...)

  approve do |req|                          # permission policy for the agent
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

- **`ask m(args) -> Type`** — a typed answer (the Llm runner's natural shape; validated/coerced).
- **`task m(args)`** — a `TurnResult`: the *work* the agent did (`.text` / `.ok?` / `.edits` / `.commands` / `.plan` / `.files` / `.tool_calls`), not a coerced schema.
- **`model X`** = in-process LLM runner; **`drives "cmd"`** = drive an external [ACP](https://agentclientprotocol.com) agent (Claude Code via `claude-code-acp`, Codex via `npx @zed-industries/codex-acp`, …) — or `drives "claude"` to drive the Claude Code CLI **directly**, no adapter. Sessions persist (memory), output streams, fs/terminal are sandboxed.
- **`tool …`** — other agents / functions / MCP servers the agent can call.
- **`approve do |req|`** (or `def on_approval(req)`) — gate the agent's permission requests (`:allow` / `:deny`).
- **`.stream do |ev|`** — structured turn events: `{:text, _}` `{:thought, _}` `{:tool_call, _}` `{:plan, _}`.

See [`docs/agent_design.md`](docs/agent_design.md) and the [ACP protocol sequences](docs/acp_sequence.md).
Want to run an agent right now with no API key? The next section drives these from
your editor on a local LLM (Ollama).

### Agents in your editor (over ACP)

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
  ask reply(message)                       # free-text answer, streamed
end
```

**2. A real agent** — it answers about a file without touching disk: it asks *your
editor* to read it, mid-turn, over the same ACP connection.

```ruby
agent Reader
  model "ollama:qwen3.6:35b-a3b"
  role "Call read_file with the path you're given, then answer strictly from its contents."
  ask describe(request)
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
  ask review(topic)
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

### …or in a web UI (Jet Console)

The same agents run in **[Jet Console](console/)** — a Phoenix LiveView web app, pure BEAM
(**no Node, no Electron**): projects, **parallel** threads, a markdown conversation, an embedded
terminal, and a live plan + tool-activity panel. Pick a backend per thread (a local model, any
ACP agent, **or** the Claude Code CLI driven directly), build agents with a no-code form, and
isolate a thread in its own git worktree.

![Jet Console — a Forge agent on the native Claude CLI driving a Pipeline team, with the live plan + tool-activity panel on the right, a markdown conversation, and a clean project/thread sidebar](docs/img/console-hero.png)

```sh
cd console && mix setup && mix phx.server   # → http://localhost:4000
```

More screenshots — the [parallel-threads board, the no-code agent builder, the file viewer, and the terminal](console/README.md#screenshots).

### Collaboration shapes — swap the topology, keep the interface

`Fleet` is one *shape*. Behind the same `agent` + `ask`/`task`, the **runner** picks *how*
a turn is run, and every shape below is just "a runner module + one dispatch line" over a
shared substrate (`jet_backend`: resolve a member to `{:ollama, model}` | `{:acp, command}`,
run it, return text). So they all inherit the same things for free: members run as
**monitored BEAM processes** (crash-isolated — kill one, the rest still deliver), output
**streams**, and each is **ACP-servable** (drive it from an ACP client) *and* usable directly
(`spawn().m().await()`). A member is a local model (`model:`) or any external ACP agent
(`drives:` — Claude Code, Codex, Gemini, …); the backend is the user's choice, never assumed.

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
[Goal](examples/acp_goal_demo.jet) · [Codegen](examples/acp_codegen_demo.jet).

**Add your own shape** — a `turn/4` module + one `dispatch/4` case (the `runner Name(...)` DSL
resolves the name generically, so no parser change): see
[Adding your own shape](docs/agent_design.md#67-adding-your-own-shape).

Jet also speaks **MCP**, both directions. As a **client**, an agent **consumes**
external MCP servers it declares with `mcp "…"` — their tools become callable mid-turn
([`examples/agent_mcp_demo.jet`](examples/agent_mcp_demo.jet)). As a **server**,
`jet_mcp::handle` answers `tools/list` / `tools/call`, so an agent's `tool`s can be
exposed to an MCP client (protocol core + a runnable test in
[`examples/test_mcp.jet`](examples/test_mcp.jet); the stdio server loop isn't wired
into the CLI yet).

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
$ gleam test
```
