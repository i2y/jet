# jet_orchestra Tutorial

A multi-agent orchestration framework for the Jet language, built on BEAM/OTP.

## What is jet_orchestra?

jet_orchestra is a framework for building multi-agent systems that:

- Receive tasks via polling, push (direct submission), or both (hybrid)
- Configure everything declaratively via WORKFLOW.md (YAML + prompt template)
- Dispatch AI agent workers to solve each task in isolated workspaces
- Handle multi-turn execution, retries with exponential backoff, and stall detection
- Monitor PR reviews and automatically address reviewer feedback
- Recover from worker crashes (OTP monitoring) and machine restarts (checkpoint persistence)
- Execute lifecycle hooks (setup, teardown, CI) at each stage

## Architecture Overview

```
                                WORKFLOW.md
                               (YAML + template)
                                     |
                                     v
                                Config::from_workflow()
                                     |
  Push (Webhook / MQ)    Poll        v         Store (FileStore)
         |                |     +---------+          |
         v                v     | Config  |          v
  +------+----------------+----+---------+----+----------+
  |                    Scheduler (Actor)                  |
  |  submit / reconcile -> claim -> dispatch -> monitor   |
  |       ^                           |            |      |
  |       | :tick / :review_tick      | spawn      |      |
  |       +---------------------------+            |      |
  |                                    v           |      |
  |                            Worker (Actor)  <---+      |
  |                            Workspace + Hooks          |
  |                            Runner (Claude, ...)       |
  |                            turn 1 -> N                |
  |                                    |                  |
  |                            {:worker_done}             |
  |                                    v                  |
  |                            Retry / Done               |
  |                                    |                  |
  |                            review_pending             |
  |                                    ^                  |
  |                   GitHubPRReviewSource                 |
  +-------------------------------------------------------+
```

### Module Map

```
src/jet_orchestra/
├── Scheduler.jet       # Task scheduler (orchestrator)
├── Worker.jet          # Multi-turn worker (workspace reuse for reviews)
├── Config.jet          # Settings, hooks, workflow loading
├── Workflow.jet        # WORKFLOW.md parser + {{template}} renderer
├── WorkflowRouter.jet  # Multi-workflow routing (label-based)
├── Runner.jet          # Agent runner protocol
├── TaskSource.jet      # Task source protocol
├── Store.jet           # Persistence protocol
├── FileStore.jet       # JSON checkpoint persistence
├── DetsStore.jet       # DETS per-task persistence
├── Workspace.jet       # Isolated directory management
├── Hooks.jet           # Lifecycle hook execution
├── Backoff.jet         # Retry strategies
├── Log.jet             # Structured logging
└── PythonBridge.jet    # BEAM <-> Python interop

src/jet_orchestra_runners/
├── ClaudeSimpleRunner.jet  # claude --print via os::cmd
├── ClaudeCodeRunner.jet    # claude --print via port
├── ClaudeAgentRunner.jet   # Claude Agent SDK via Python
└── CodexRunner.jet         # Codex JSON-RPC

src/jet_orchestra_sources/
├── GitHubTaskSource.jet       # GitHub Issues (gh CLI)
├── GitHubPRReviewSource.jet   # PR review comment monitoring
└── LinearTaskSource.jet       # Linear API (GraphQL)
```

## Getting Started

### Prerequisites

- Erlang/OTP >= 26.0
- Gleam >= 1.0
- `gh` CLI (for GitHub integration)

### Setup

```sh
# Clone and build the Jet compiler
git clone https://github.com/i2y/jet.git
cd jet
gleam build && gleam export erlang-shipment && escript build_escript.erl

# Compile the standard library and orchestra modules
./jet build src/
./jet build src/jet_orchestra/
./jet build src/jet_orchestra_runners/
./jet build src/jet_orchestra_sources/
```

The `./jet` binary and compiled `.beam` files are now ready. You can write your orchestra app anywhere inside this directory.

### Your First Orchestra App

Create `my_orchestra.jet`:

```jet
module MyOrchestra
  def self.main()
    config = Config::new({
      mode: :push,
      max_concurrent: 3,
      max_turns: 5,
      workspace_root: "/tmp/my_orchestra"
    })
    orch = Scheduler::Instance.spawn(config, nil, :ClaudeSimpleRunner, {
      store: :DetsStore
    })
    orch.submit({id: "task-1", title: "Fix the login bug", description: "Users can't log in"})
    timer::sleep(60000)  # wait for task to complete
    puts("Completed: ~p", [orch.completed()])
  end
end
```

```sh
./jet -r MyOrchestra::main my_orchestra.jet
```

Or build a standalone executable:

```sh
./jet escript MyOrchestra .
./myorchestra
```

## Quick Start

### The Simplest Way: WORKFLOW.md

Create a `WORKFLOW.md` file:

```yaml
---
max_turns: 5
max_concurrent: 3
workspace_root: /tmp/orchestra

hooks:
  after_create: "git clone https://github.com/$ORCHESTRA_GITHUB_REPO . && git checkout -b orchestra-$ORCHESTRA_TASK_ID"
  before_run: "git pull origin main --no-edit 2>/dev/null; true"
  after_run: "git add -A && git commit -m 'fix' && git push -u origin HEAD && gh pr create --fill 2>/dev/null; true"
  before_review_run: "git fetch origin && git pull --no-edit 2>/dev/null; true"
  after_review_run: "git add -A && git commit -m '[orchestra] address review' && git push; true"

review:
  max_rounds: 5

allowed_tools: "Read Edit Write Bash(python:*) Bash(pytest:*)"
---
You are a software engineer. Fix this issue:
Title: {{task.title}}
Description: {{task.description}}
Attempt: {{attempt}}
```

Then use it:

```jet
module MyOrchestra
  def self.run()
    config = Config::from_workflow("WORKFLOW.md")
    orch = Scheduler::Instance.spawn(config, :GitHubTaskSource, :ClaudeSimpleRunner, {
      store: :FileStore,
      review_source: :GitHubPRReviewSource
    })
    # Scheduler polls issues, runs Claude, creates PRs, handles review feedback
  end
end
```

```sh
ORCHESTRA_GITHUB_REPO=myorg/myrepo ./jet -r MyOrchestra::run MyOrchestra.jet
```

### Programmatic Configuration

Everything in WORKFLOW.md can also be set in code:

```jet
config = Config::new({
  mode: :hybrid,
  max_concurrent: 3,
  max_turns: 5,
  workspace_root: "/tmp/orchestra",
  after_create_hook: "git clone ... .",
  before_run_hook: "npm install",
  after_run_hook: "git push && gh pr create --fill",
  before_review_run_hook: "git fetch && git pull",
  after_review_run_hook: "git add -A && git commit -m '[orchestra] review' && git push",
  max_review_rounds: 5,
  allowed_tools: "Read Edit Write Bash(python:*)"
})
```

Hooks in `opts` override those in Config:

```jet
# Config provides base hooks, opts can override specific ones
orch = Scheduler::Instance.spawn(config, source, runner, {
  hooks: {after_run: "custom override"}  # overrides config.after_run_hook
})
```

### Push Mode

```jet
config = Config::new({mode: :push, max_concurrent: 3})
orch = Scheduler::Instance.spawn(config, nil, nil, {})
orch.submit({id: "1", title: "Fix bug", description: "..."})
```

### Multi-Workflow Routing

Different task types (bug, feature, review) can use different workflows. The Scheduler automatically selects the right workflow per task based on its labels, using a 3-tier fallback:

1. **`workflow_router`** (module) — maximum flexibility. You implement `Module::select(task) -> path`.
2. **`workflows`** (map) — label-to-path lookup table.
3. **`workflow_dir`** (directory) — automatic label-to-filename matching.
4. (none) — single workflow behavior (backwards compatible).

Workflow routing is task-source agnostic — it works with GitHub, Linear, push mode, or any custom source. The only requirement is that tasks have a `labels` field (list of strings). `GitHubTaskSource` and `LinearTaskSource` populate this automatically; for push mode, include labels when submitting.

#### Directory Mode (simplest)

```jet
# Create workflows/bug.md, workflows/feature.md, workflows/default.md
config = Config::new({workflow_dir: "workflows/"})

# Works with any task source:
orch = Scheduler::Instance.spawn(config, :GitHubTaskSource, :ClaudeSimpleRunner, {})
orch = Scheduler::Instance.spawn(config, :LinearTaskSource, :ClaudeSimpleRunner, {})

# Also works with push mode — just include labels in the task:
orch = Scheduler::Instance.spawn(config, nil, :ClaudeSimpleRunner, {})
orch.submit({id: "1", title: "Fix crash", labels: ["bug"]})
orch.submit({id: "2", title: "Add dark mode", labels: ["feature"]})

# Task with labels: ["bug"] -> workflows/bug.md
# Task with labels: ["feature"] -> workflows/feature.md
# Task with unknown labels -> workflows/default.md
```

#### Map Mode

```jet
config = Config::new({workflows: {
  bug: "wf/bug.md",
  feature: "wf/feat.md",
  default: "wf/default.md"
}})
```

#### Router Module Mode (maximum flexibility)

```jet
module MyRouter
  def self.select(task)
    labels = maps::get(:labels, task, [])
    if lists::member("urgent", labels)
      "workflows/urgent.md"
    elsif lists::member("bug", labels)
      "workflows/bug.md"
    else
      "workflows/default.md"
    end
  end
end

config = Config::new({workflow_router: :MyRouter})
```

Each workflow file uses the same WORKFLOW.md format (YAML front matter + prompt template). Settings from the selected workflow override the base config — only values explicitly set in the workflow file are overridden.

Workflow files are cached by path with mtime-based invalidation, so editing a workflow file takes effect on the next task without restarting the Scheduler.

## Configuration Reference

### Config Fields

| Field | Default | Description |
|---|---|---|
| `mode` | `:poll` | `:poll`, `:push`, or `:hybrid` |
| `poll_interval_ms` | 30000 | Task polling interval |
| `max_concurrent` | 5 | Max parallel workers |
| `max_turns` | 10 | Max agent turns per task |
| `max_retries` | 3 | Max retries on failure |
| `max_retry_backoff_ms` | 300000 | Max backoff delay |
| `stall_timeout_ms` | 300000 | Stall detection timeout |
| `workspace_root` | `/tmp/orchestra` | Workspace base directory |
| `hook_timeout_ms` | 60000 | Hook execution timeout |
| `max_review_rounds` | 5 | Max PR review cycles |
| `review_poll_interval_ms` | 60000 | Review comment polling interval |
| `allowed_tools` | `Read Edit Write Bash(python:*) Bash(pytest:*) Bash(git:*)` | Claude CLI allowed tools |
| `after_create_hook` | nil | Shell command after workspace creation |
| `before_run_hook` | nil | Shell command before each agent turn |
| `after_run_hook` | nil | Shell command after agent completes |
| `before_remove_hook` | nil | Shell command before workspace deletion |
| `before_review_run_hook` | nil | Shell command before review turn |
| `after_review_run_hook` | nil | Shell command after review turn |
| `workflow_path` | nil | Path to WORKFLOW.md (set by `from_workflow`) |
| `prompt_template` | nil | Prompt template string (set by `from_workflow`) |
| `workflow_dir` | nil | Directory of workflow files for label-based routing |
| `workflow_router` | nil | Module implementing `select(task) -> path` |
| `workflows` | nil | Map of `label -> workflow_path` |

### WORKFLOW.md Format

```yaml
---
# Flat keys
max_turns: 5
max_concurrent: 3
poll_interval_ms: 30000
workspace_root: /tmp/orchestra
mode: hybrid
allowed_tools: "Read Edit Write"

# Nested keys
hooks:
  after_create: "..."
  before_run: "..."
  after_run: "..."
  before_remove: "..."
  before_review_run: "..."
  after_review_run: "..."
  timeout_ms: 60000

review:
  max_rounds: 5
  poll_interval_ms: 60000
---
Prompt template with {{task.title}}, {{task.description}}, {{attempt}} variables.
```

### Hooks

```
Workspace created --> after_create --> before_run --+
                                                    |
                                     [Agent turn] <-+ (multi-turn)
                                                    |
                                     after_run -----+
                                        |
                                   (if review)
                                        |
                              before_review_run --+
                                                  |
                               [Agent addresses  <-+
                                review comments]   |
                                                  |
                              after_review_run ---+
                                        |
                                   before_remove --> Workspace deleted
```

For review tasks, `before_review_run`/`after_review_run` are used if defined; otherwise falls back to `before_run`/`after_run`.

Environment variables: `$ORCHESTRA_TASK_ID`, `$ORCHESTRA_TASK_TITLE`

## Protocols

| Protocol | Functions | Built-in |
|---|---|---|
| **Runner** | `run/4`, `stop/1` | `Runner`, `ClaudeSimpleRunner`, `ClaudeCodeRunner`, `ClaudeAgentRunner`, `CodexRunner` |
| **TaskSource** | `fetch_tasks/1`, `update_task/3`, `fetch_task_state/2` | `TaskSource`, `GitHubTaskSource`, `LinearTaskSource` |
| **Store** | `save/2`, `load/1`, `delete/1`, `save_task/3`*, `load_task/2`*, `delete_task/2`*, `list_task_ids/1`* | `Store`, `FileStore`, `DetsStore` |
| **ReviewSource** | `fetch_tasks/1` | `GitHubPRReviewSource` |

### GitHub Authentication

```sh
gh auth login        # interactive
gh auth status       # verify
```

```jet
GitHubTaskSource::check_auth()  # => :ok | {:error, msg}
```

## PR Review Loop

When `review_source: :GitHubPRReviewSource` is configured:

```
Issue open --> Agent fix --> PR created --> review_pending
    --> Reviewer posts comments
    --> GitHubPRReviewSource detects new comments
    --> Review child task "ID-review-N" submitted
    --> Worker reuses workspace, Claude addresses feedback
    --> after_review_run hook pushes fix
    --> Repeat until APPROVED or max_review_rounds
```

Comments containing `[orchestra]` are filtered out to prevent self-loops.

## Persistence

### FileStore (JSON bulk checkpoint)

```jet
orch = Scheduler::Instance.spawn(config, source, runner, {store: :FileStore})
# Checkpoint: <workspace_root>/.orchestra/checkpoint.json
# Persists: claimed, retry_attempts, done, completed, review_pending
```

On restart with the same config + store, task state is automatically restored.

### DetsStore (DETS per-task persistence)

```jet
orch = Scheduler::Instance.spawn(config, source, runner, {store: :DetsStore})
# DETS file: <workspace_root>/.orchestra/state.dets
# Per-task updates: only the changed task is written, not the entire state
```

DetsStore advantages over FileStore:
- **No JSON serialization** — stores native Erlang terms directly
- **Per-task updates** — when one task completes, only that task's record is written (not the full state)
- **Concurrent-access safe** within the same BEAM node

The Scheduler automatically detects `supports_per_task?()` and uses per-task persistence when available. Bulk API (`save/load/delete`) is also supported for compatibility.

Per-task API (* = optional, only for stores with `supports_per_task?() == true`):

| Function | Description |
|---|---|
| `save_task(root, id, data)` | Save a single task record |
| `load_task(root, id)` | Load a single task record |
| `delete_task(root, id)` | Delete a single task record |
| `list_task_ids(root)` | List all stored task IDs |
| `save_meta(root, data)` | Save metadata (claimed order) |
| `save_review(root, id, data)` | Save review tracking data |

## Compilation & Testing

```sh
gleam build && gleam export erlang-shipment && escript build_escript.erl
for f in src/jet_orchestra/*.jet; do ./jet "$f"; done
for f in src/jet_orchestra_runners/*.jet src/jet_orchestra_sources/*.jet; do ./jet "$f"; done
gleam test  # 51 tests

# Jet runtime tests
./jet -r TestBackoff::run examples/orchestra/TestBackoff.jet
./jet -r TestConfig::run examples/orchestra/TestConfig.jet
./jet -r TestLog::run examples/orchestra/TestLog.jet
./jet -r TestWorkspace::run examples/orchestra/TestWorkspace.jet
./jet -r TestRunner::run examples/orchestra/TestRunner.jet
./jet examples/orchestra/MockTaskSource.jet
./jet -r TestScheduler::run examples/orchestra/TestScheduler.jet
./jet -r TestPushMode::run examples/orchestra/TestPushMode.jet
./jet -r TestPersistence::run examples/orchestra/TestPersistence.jet
./jet -r TestDetsStore::run examples/orchestra/TestDetsStore.jet
./jet -r TestWorkflowRouter::run examples/orchestra/TestWorkflowRouter.jet
./jet -r WorkflowDemo::run examples/orchestra/WorkflowDemo.jet
```
