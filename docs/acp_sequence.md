# ACP Runner — Protocol Sequences

How Jet's `Acp` runner (`runner Acp(command: "claude-code-acp")`) talks to a real
external AI agent over the **Agent Client Protocol** (ndjson JSON-RPC 2.0 over
stdio). Each section shows the user-side Jet code that drives one call, then the
sequence it expands into on the wire. Observed against the real
`@zed-industries/claude-code-acp` (Claude Code over ACP).

> The runner is **agent-agnostic**: the same `jet_acp` drives any ACP agent —
> just swap the command. e.g. `npx @zed-industries/codex-acp` for OpenAI Codex
> (see [`examples/agent_codex.jet`](../examples/agent_codex.jet)), or a Gemini
> CLI adapter. Codex's own *App Server* is a separate protocol that the
> `codex-acp` adapter bridges to ACP.

- **Jet side = ACP _client_** — the per-agent connection process (`jet_acp`). This is your `agent`.
- **External side = ACP _agent_** — the spawned subprocess; inside it runs the actual LLM (Claude Agent SDK).
- **Transport** — one JSON-RPC message per `\n`-delimited line, on the subprocess's stdin/stdout. stderr is kept separate (`separate_stderr`) so stdout carries only protocol.

The defining property is that it is **bidirectional**: mid-turn, the agent calls
*back* into Jet for permissions, filesystem, and terminal. The LLM is the "head";
Jet is its "hands and feet" (the sandboxed execution environment).

```mermaid
graph LR
    subgraph Jet["Jet — ACP client (jet_acp)"]
        A["agent Researcher"] --> C["connection process<br/>(1 per agent, owns the port)"]
    end
    subgraph Ext["external ACP agent (subprocess)"]
        L["LLM loop<br/>(Claude Agent SDK)"]
    end
    C -- "initialize / session.new / session.prompt" --> L
    L -. "session.update (stream)" .-> C
    L -- "request_permission / fs.* / terminal.*  (callbacks)" --> C
    C -. "you provide: approval, sandboxed fs, command exec" .-> L
```

## Usage (the trigger for every sequence)

A Jet user writes only this: declare an `agent`, `spawn()` it, call a method.
`agent` desugars to an `actor` (gen_server) + a runner, and method calls are
**async** (they return a `Future`) — `.await()` for the result, or
`.stream do |chunk| … end` for incremental output.

```ruby
agent Researcher
  runner Acp(command: "claude-code-acp")     # drive an external agent over ACP
  role "You research rigorously and cite sources."
  expose research(question) -> {answer: String, sources: [String]}  # structured result
  expose task(instruction)                                          # no schema -> text
end

r = Researcher.spawn()                         # §1: the connection comes up
r.research("What is the BEAM?").await()        # §2: one turn => {:ok, {answer, sources}}
r.research("…").stream do |chunk|              # §5: streaming
  io::format("~ts", [chunk])
end
```

Each section below shows how one of these calls expands on the wire. Runnable
example: [`examples/agent_acp.jet`](../examples/agent_acp.jet) (uses a local mock ACP).

## 1. Connection setup (once per agent)

```ruby
r = Researcher.spawn()
```

`spawn()` starts the connection process and runs `initialize → session/new` once.
The resulting `sessionId` is held in `r`'s state and reused for every turn
(= conversation memory).

```mermaid
sequenceDiagram
    autonumber
    participant J as Jet (ACP client)
    participant A as claude-code-acp (agent)
    Note over J: agent.spawn() → start connection process
    J->>A: spawn subprocess "claude-code-acp"
    J->>A: initialize (protocolVersion=1, clientCapabilities{fs})
    A-->>J: result (protocolVersion, agentInfo, authMethods)
    J->>A: session/new (cwd, mcpServers=[])
    A-->>J: result (sessionId "64ffa3ef-…")
    Note over J: store sessionId — reused across turns
```

## 2. A turn — the bidirectional dance

```ruby
r.task("write hello to notes.txt").await()
# task has no schema -> the result is text: {:ok, "Done."}
```

You only `await()`. But inside this one turn the agent calls *back* into Jet for
permission (`request_permission`) and `fs/write_text_file`; Jet serves those and
the turn proceeds (the middle of the diagram).

```mermaid
sequenceDiagram
    autonumber
    participant Caller as caller (your code)
    participant J as Jet connection
    participant A as agent (LLM)
    Caller->>J: r.task("write hello to notes.txt")  (async ⇒ Future)
    J->>A: session/prompt (sessionId, prompt[text])

    A--)J: session/update — agent_thought_chunk
    A--)J: session/update — tool_call (id=t1, kind=edit, status=pending)

    A->>J: session/request_permission (options[allow,…])
    J-->>A: result (outcome selected=allow)

    A->>J: fs/write_text_file (path, content="hello")
    Note over J: within_sandbox?(path) → file::write_file
    J-->>A: result (null)

    A--)J: session/update — tool_call_update (id=t1, status=completed)
    A--)J: session/update — agent_message_chunk ("Done.")
    Note over J,Caller: each chunk ⇒ {ref,{:item,chunk}} ⇒ .stream callback

    A-->>J: result (stopReason "end_turn")
    Note over J: parse vs schema → {:ok, result}
    J--)Caller: Future resolves ⇒ .await() returns
```

Legend: solid `->>` = request (expects a response), dashed `-->>` = response,
open `--)` = notification (no response). Requests **from the agent** (permission,
`fs/*`, `terminal/*`) are the callbacks Jet must answer.

`stopReason` ∈ `end_turn | refusal | max_tokens | max_turn_requests | cancelled`.
`refusal` is surfaced as `{:error, :refusal}`. With a schema-typed method the
result is validated and coerced to a typed Jet value, e.g.
`{:ok, {answer: …, sources: […]}}`.

Permission requests route to the agent's optional `on_approval(req)` (default
`:allow`) — return `:deny` to refuse, or a specific `optionId`:

```ruby
def on_approval(req)
  match req.get(:kind)        # "execute" | "edit" | "read" | …
    case "execute"
      :deny                   # e.g. never let it run shell commands
    case _
      :allow
  end
end
```

## 3. Deep dive — `tool_call` lifecycle

```ruby
r.task("run the tests with mix test, then summarize failures").await()
# an execute tool -> terminal/create -> wait_for_exit -> output callbacks (below)
```

From the caller it's the same single call; whether to use a tool is the agent's
decision. When it does, it streams a `session/update` with
`sessionUpdate: "tool_call"`, then one or more `tool_call_update`s. The shape
(ACP schema v1):

| field | meaning |
|---|---|
| `toolCallId` | stable id correlating the call and its updates |
| `title` | human label ("Write notes.txt") |
| `kind` | `read · edit · delete · move · search · execute · think · fetch · switch_mode · other` |
| `status` | `pending → in_progress → completed \| failed` |
| `content` | output blocks — `content` (text), `diff` (file diff), or `terminal` (links a `terminalId`) |
| `locations` | `{path, line}` the tool touches — lets a UI "follow along" in the editor |
| `rawInput` / `rawOutput` | provider-raw tool args/result |

A tool call usually *also* triggers a callback Jet must serve (the actual side
effect). e.g. an `execute` tool:

```mermaid
sequenceDiagram
    autonumber
    participant J as Jet connection
    participant A as agent
    A--)J: tool_call (id=t2, kind=execute, title "Run tests", status=pending)
    A->>J: terminal/create (command="mix", args=["test"])
    Note over J: run_command → port (exit_status, stderr_to_stdout)
    J-->>A: result (terminalId "term-42")
    A->>J: terminal/wait_for_exit (terminalId "term-42")
    J-->>A: result (exitCode 0, signal null)
    A->>J: terminal/output (terminalId "term-42")
    J-->>A: result (output "…", truncated false, exitStatus{exitCode 0})
    A--)J: tool_call_update (id=t2, status=completed, content[terminal t2→term-42])
```

Commands run with the session root as cwd, and `fs/*` is confined to the sandbox.
(v1 runs the command **synchronously** inside `terminal/create`; streaming /
long-running terminals are a follow-up.)

## 4. Deep dive — multiple / parallel tools

```ruby
r.task("read config.exs and write a sanitized copy to config.sample.exs").await()
# multiple tools (fs/read + fs/write) in one turn; still a single call.
```

The agent may interleave several tool calls in one turn, each with a distinct
`toolCallId`. They share **one** connection, so Jet serves the callbacks **in
arrival order**, one at a time — a selective `receive` on the port keeps each
tool's bytes separate. Updates are correlated by `toolCallId`, so a UI can render
several tool cards updating independently even though the client serves them
sequentially.

```mermaid
sequenceDiagram
    autonumber
    participant J as Jet connection
    participant A as agent
    A--)J: tool_call (id=t3, kind=read,  status=pending)
    A--)J: tool_call (id=t4, kind=edit,  status=pending)
    A->>J: fs/read_text_file (path A) — serves t3
    J-->>A: result (content …)
    A--)J: tool_call_update (id=t3, status=completed)
    A->>J: fs/write_text_file (path B) — serves t4
    J-->>A: result (null)
    A--)J: tool_call_update (id=t4, status=completed)
```

Caveat: because `terminal/create` runs synchronously in v1, a long command blocks
the read loop until it exits (other interleaved messages queue, then drain).
Async/streaming terminals would remove that — a noted follow-up.

## 5. Deep dive — streaming to `.stream do |chunk| … end`

```ruby
r.research("Summarize BEAM scheduler design in 3 points").stream do |chunk|
  io::format("~ts", [chunk])      # called per chunk (to a TUI / WebSocket / LiveView)
end
# the block is called per chunk; the final result ({:ok, {answer, sources}}) is returned
```

`.await()` waits for just the result; `.stream do …` passes each intermediate chunk
to the `do` block and still returns the final result. That one line is the only
difference in user code.

```mermaid
sequenceDiagram
    autonumber
    participant Caller as caller (.stream)
    participant J as Jet connection
    participant A as agent
    Caller->>J: r.research("…")  (Future with ref R)
    J->>A: session/prompt
    loop each agent_message_chunk
        A--)J: session/update — agent_message_chunk
        J--)Caller: {R, {:item, chunk}}
        Note over Caller: AsyncResult.stream ⇒ callback.(chunk)  (update UI / print)
    end
    A-->>J: result (stopReason end_turn)
    J--)Caller: {R, {:done, {:ok, result}}}
    Note over Caller: stream/await returns the final result
```

The `do` block runs in the caller process, so it can print tokens, push to a
WebSocket/LiveView, or update a TUI as they arrive — backpressure is natural (the
connection only advances as the caller consumes).

## 6. Multi-turn (session reuse = memory)

```ruby
r.task("Remember the number 42.").await()    # turn 1
r.task("What number did I say?").await()      # turn 2 => {:ok, "42"} (remembered)
```

Calling on the same `r` (same connection, same `sessionId`) continues the
conversation. The second turn skips setup and reuses the stored `sessionId`; the
agent retains prior context.

```mermaid
sequenceDiagram
    autonumber
    participant J as Jet connection
    participant A as agent
    Note over J,A: (connection + sessionId already established)
    J->>A: session/prompt #1 ("Remember the number 42.")
    A-->>J: result (end_turn)  — reply "OK"
    J->>A: session/prompt #2 ("What number did I say?")
    A-->>J: result (end_turn)  — reply "42"   ✅ remembered
```

Verified live: turn 2 answered **"42"**. One connection process per agent owns
one ACP session for the agent's lifetime; it `monitor`s the agent and exits when
the agent dies.

## 7. Reference — implementation map (`src/jet_acp.jet`)

You write only the code above; internally `jet_acp` handles the protocol:

| sequence step | `jet_acp` (and friends) |
|---|---|
| spawn + initialize + session/new | `open_connection → connection_init → init_session` |
| receive a turn, send prompt | `connection_loop` (`{:turn}`) → `run_prompt` → `send_req("session/prompt")` |
| pump the ndjson stream | `await` (split on `\n`) → `handle_line` → `dispatch` |
| accumulate / stream chunks | `accumulate → append_content → emit_item` (→ caller) |
| answer agent callbacks | `handle_server_request` → `handle_fs_* / handle_terminal_* / permission` |
| sandbox check | `within_sandbox?` (reject `..`, require under session root) |
| structure the result | `parse_result` (decode → `jet_agent::coerce` → `jet_agent::validate`) |
| caller side | `jet_agent.AsyncResult` (`await` / `stream`) |

## 8. Status & limits

Implemented and verified against real `claude-code-acp`: initialize/session, the
prompt turn, streaming, session reuse (memory), `fs/read|write_text_file`,
`terminal/*`, permission via an `on_approval` hook (default allow), and
schema-parse of structured output.

Follow-ups: symlink-tight fs sandbox, async/streaming
terminals, and surfacing `tool_call`/`plan` updates to the caller (not just text
chunks).
