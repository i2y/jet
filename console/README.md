# Jet Console — Phoenix LiveView frontend

An **editor-less** web UI for Jet agents — projects, threads, a local model / an ACP agent / the
Claude Code CLI per thread, a markdown conversation, and a live plan + tool-activity sidebar.
Pure BEAM: **no Node, no Electron** (Bandit + esbuild/tailwind standalone binaries).

![Jet Console — a Forge agent on the native Claude CLI driving a Pipeline team, with the live plan + tool-activity panel on the right](../docs/img/console-hero.png)

This dir is the **complete, runnable app** — the whole Phoenix shell + the LiveView, the vendored
browser JS, and the agents are committed here (it's an **opt-in** component of the Jet repo: a UI
alternative to driving agents from an ACP client or the CLI). It loads the Jet runtime from `JET_ROOT`.

**Prerequisites:** [Elixir](https://elixir-lang.org) `~> 1.15` (it brings Erlang/OTP) and the
built `jet` escript — see the repo-root [README](../README.md#installation). `mix setup` pulls
Phoenix and the rest; esbuild/tailwind are standalone binaries (no Node).

**Run it:**
```sh
cd console
mix setup                                  # deps + esbuild/tailwind + build assets
( cd .. && for f in src/*.jet; do ./jet "$f"; done )   # compile the Jet stdlib beams once
mix phx.server                             # -> http://localhost:4000
```
`JET_ROOT` defaults to the parent of this `console/` directory (i.e. the Jet repo you cloned);
set `JET_ROOT=/path/to/jet` to point elsewhere. Run `mix phx.server` from inside `console/`.
Local models are unset by default — open **Settings (🔌)** and pick an installed Ollama model
(it auto-detects what you have). The internal app module is `Jc`/`:jc`.

Set `JET_PROJECT_DIR` to the folder you want the agents to work in (defaults to the server cwd).

## Screenshots

**Parallel threads — a board of agents working at once**, each its own BEAM process with its own
backend and its own live plan/tool structure.

![The parallel-threads board — Verified Coder and two Forge runs, each with its round/team structure and status](../docs/img/console-board.png)

**File viewer with rendered Markdown** (also HTML in a sandboxed iframe, images, and
syntax-highlighted source) — browse the project (or a thread's git worktree); toggle 👁 Preview / ✎ Source.

![The file viewer — the project tree on the left and a rendered README.md preview](../docs/img/console-files.png)

**No-code agent builder** — compose / edit / delete agents in the browser; **Save** recompiles the
`.jet` file with the `jet` escript and hot-loads the new beam into the picker (no restart).

![The Agents panel — a no-code builder, backend settings, and a raw .jet editor in one tabbed panel](../docs/img/console-builder.png)

**Embedded terminal, per thread** — a PTY-backed shell docked below the conversation, opened in
that thread's cwd (project or git worktree) and surviving a browser reload.

![A per-thread terminal docked below the conversation, in the project's directory](../docs/img/console-terminal.png)

## How it works

- **Projects** — a project is a **folder**. The node cwd is set to it (`File.cd!`), so
  claude-code-acp uses it as the ACP session cwd and local `jet_fs` tools resolve relative
  paths there ("open a folder"). Default = `JET_PROJECT_DIR` or the server cwd.
- **Agents = editable `.jet` files** — the backend picker is built from `agents/*.jet`. Each is
  a Jet module exporting `catalog/0` (`[{key, "Label"}]`) and `spawn_for/1` (`key -> pid`); the
  console aggregates every file's catalog. The **🤖 Agents** panel (top bar) lets you add / edit /
  delete agents in the browser — a no-code **builder** form, the **backend settings**, and a raw
  **`.jet` editor**, in one tabbed panel; **Save** recompiles the file with the `jet` escript and
  **hot-loads** the new beam — no restart. `Jc.AgentStore` does the compile/load/CRUD;
  call `Jc.AgentStore.load_all()` from `Application.start/2`. Config: `JET_ROOT` (the jet
  repo with the `jet` escript), `JET_AGENTS_DIR` (default `<JET_ROOT>/console/agents`).
  `agents/builtin.jet` seeds the set (Local Assistant, Jet Coder, Researcher, Claude Code (ACP),
  Claude Code (native CLI), Jet Forge, Verified Coder, Routed).
- **Threads** — each thread drives its own selected agent; switch/create freely. Threads + their
  conversation **persist** via `Jc.ThreadStore` (add it to the supervision tree): in
  memory across a LiveView reconnect, and on disk (`$JET_CONSOLE_STATE` or
  `~/.jet_console.threads`) across a server restart — a restored thread re-spawns its agent on
  the next message.
- **Streaming** — on send, a process runs `:jet_console.run_to_tagged(agent, :chat, [msg],
  self(), thread_id)`, forwarding the SAME structured events the ACP server emits,
  tagged by thread: `{:jet_event_tag, id, ev}` then `{:jet_done_tag, id, result}`.
  `handle_info` folds each event into that thread's blocks.
- **Panels** — center renders user/agent (markdown via Earmark)/thought; the right sidebar
  shows the **plan** (checklist) and the **run trace** (a span tree with per-step durations, and
  per-member token counts for `Fleet`/`Flow`).
- **Metering** — the jet side meters every turn (`{:usage, …}` events); the UI shows a per-reply
  **token/cost badge** under the agent message, a per-thread **`Σ` total** in the header, and step
  durations in the trace. Cost appears only when the backend reports it (the native `claude` CLI);
  Ollama shows tokens. A turn that ends in a typed error surfaces as a red error block.

## Browser-side editor & terminal (vendored JS, no npm/Node)

Both run in the browser (served as static assets — **no Node runtime**), vendored self-contained
under `priv/static/assets/vendor/` and loaded from `root.html.heex`; the LiveView hooks live in
`assets/js/app.js`.

- **📁 Files — viewer/editor.** Browse the current thread's project (or its isolated worktree).
  Files open by **kind**: **`.md` → a rendered preview** (the same `Rich` markdown → mermaid +
  highlighted code; toggle **👁 Preview / ✎ Source**); **images** (`.png/.jpg/.gif/.svg/...`) →
  shown inline via a `data:` URI; other **binary** → a "can't display" note; **> 2 MB** (e.g.
  `erl_crash.dump`, logs) → a "too large" note (never read — guard on `File.stat` size *before*
  `File.read`, or it freezes the browser). Text files use **CodeMirror 5** (`fromTextArea`, line
  numbers + syntax by extension, `material-darker` in dark mode); Save writes the file. Always
  classify with `String.valid?/1` so binary bytes are never rendered as text (that crashes the
  LiveView render).
- **Rich chat/context rendering.** A `Rich` hook on the conversation (and the 📖 context viewer)
  **syntax-highlights** code blocks (**highlight.js**, `vendor/hl/`) and renders **` ```mermaid `**
  fences as **diagrams** (**mermaid**, `vendor/mermaid.min.js`). It debounces, so it processes
  after streaming settles — no per-token flicker, no rendering of half-streamed diagrams. The
  server-side colored ` ```diff ` blocks have no language class, so they're left untouched.
- **🖥 Terminal — PTY-backed shell**, docked as a **panel below the conversation**. **xterm.js**
  (`vendor/xterm/`) front-end + a server-side PTY owned by a supervised **`Jc.Terminals`** GenServer
  (not the LiveView), so a terminal — and any long-running command — **survives a browser reload**.
  It opens `Port.open({:spawn_executable, "/usr/bin/script"}, args: ["-q", "/dev/null", "sh", "-c",
  "stty cols C rows R; exec $SHELL"], cd: <thread cwd>)` — `script` allocates the PTY (no NIF,
  portable) and the initial `stty` sets the width; live resizes set the winsize out-of-band on the
  PTY device (`stty -f /dev/ttysNNN`) so they never leak into a running program. `onData →
  "term_input" → Port.command`; output → `{:term_out, …} → "term_output" → term.write`.

**Dev gotchas (learned the hard way):**
- **Asset caching.** The dev server must send `cache-control: no-store` for `/assets/*` (a tiny
  function plug before `Plug.Static`) — otherwise the browser keeps serving a *stale* `app.js`
  (the default `cache-control: public` is cached heuristically) and JS changes never reach the
  page. A `?v=` query did **not** reliably bust it; only `no-store` (or a new filename) did.
- **Vendored globals differ per bundle.** highlight.js → `window.hljs`; CodeMirror 5 →
  `window.CodeMirror`; xterm → `window.Terminal`; fit addon → `window.FitAddon.FitAddon` *or*
  `window.FitAddon` (handle both, `try`-guarded); **mermaid's dist bundle → `window.__esbuild_esm_mermaid`
  (use its `.default`), NOT `window.mermaid`**.
- **Single root element.** A LiveView render must have ONE root element — keep `<style>` *inside*
  the root `<div>`, not as a sibling, or `phx-hook` mounting misbehaves.

## Packaging as a self-contained release (no Erlang/Elixir on the target)

Because Jet **and** Phoenix both run on the BEAM, the whole thing ships as one OTP release with
the Erlang runtime baked in — **no Node, no Electron, no system Erlang/Elixir** to run it.
Verified: a ~35 MB release that boots with `bin/<app> start` and serves the full console.

1. **Bundle the Jet runtime into `priv/jet`** (escript + stdlib beams + gleam/gun deps + agents):
   ```sh
   mkdir -p priv/jet/{src,build,console}
   cp "$JET_ROOT/jet" priv/jet/jet
   cp "$JET_ROOT"/src/*.beam priv/jet/src/
   cp -R "$JET_ROOT/build/erlang-shipment" priv/jet/build/erlang-shipment
   cp -R "$JET_ROOT/console/agents" priv/jet/console/agents
   ```
2. **`application.ex`**: `add_jet_code_paths` resolves the root via `Jc.AgentStore.jet_root()`
   (which uses `JET_ROOT`, else the parent of `console/`) — so set `JET_ROOT` (step 3) to point
   at the bundle, not the checkout.
3. **`config/runtime.exs`** (prod): point `JET_ROOT` at the bundled copy:
   ```elixir
   System.put_env("JET_ROOT", System.get_env("JET_ROOT") || Path.join(:code.priv_dir(:jc), "jet"))
   ```
4. **Build** (compile BEFORE assets — Phoenix 1.8 generates colocated CSS during compile):
   ```sh
   MIX_ENV=prod mix compile
   MIX_ENV=prod mix assets.deploy
   MIX_ENV=prod mix release
   ```
5. **Run it** (ERTS is bundled — nothing else needed):
   ```sh
   SECRET_KEY_BASE=$(openssl rand -base64 48) PHX_SERVER=true PORT=4000 PHX_HOST=localhost \
     _build/prod/rel/<app>/bin/<app> start   # -> http://localhost:4000
   ```

### Single binary per OS (Burrito)

To ship **one self-contained executable** instead of a tarball + `start`, wrap the release with
[Burrito](https://github.com/burrito-elixir/burrito) — it uses Zig to bundle ERTS + the app +
`priv/jet` into a self-extracting binary, and cross-compiles macOS/Linux/Windows from one machine.

**Quickest — use the script** (it pins Zig, refreshes `priv/jet`, clears the stale-payload caches,
and builds): `./build_binary.sh [macos|linux|windows]` → `burrito_out/jc_<target>`. One-time, install
the **exact** Zig Burrito needs (**0.15.2**; the system Zig may be newer — that is fine, the script
prepends this one):

```sh
mkdir -p ~/.local/zig
curl -sL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz | tar -xJ -C ~/.local/zig
mv ~/.local/zig/zig-*-0.15.2 ~/.local/zig/0.15.2   # Linux x86_64: zig-x86_64-linux-0.15.2.tar.xz
```

The manual steps the script automates:

1. `mix.exs`: add `{:burrito, "~> 1.0"}` and a release with the Burrito step + targets:
   ```elixir
   releases: [
     jc: [steps: [:assemble, &Burrito.wrap/1],
          burrito: [targets: [macos:   [os: :darwin,  cpu: :aarch64],
                              linux:   [os: :linux,   cpu: :x86_64],
                              windows: [os: :windows, cpu: :x86_64]]]]
   ]
   ```
2. Build one target (run `mix compile` + `mix assets.deploy` first, as above):
   ```sh
   BURRITO_TARGET=macos MIX_ENV=prod mix release --overwrite   # -> burrito_out/jc_macos
   ```
3. Run the binary (self-extracts on first run; nothing else needed):
   ```sh
   SECRET_KEY_BASE=$(openssl rand -base64 48) PHX_SERVER=true PORT=4000 PHX_HOST=localhost \
     ./burrito_out/jc_macos start
   ```

Verified: a **~17 MB** `jc_macos` Mach-O arm64 binary (v0.4.0) that boots and serves the **full**
console standalone — the cleaned agent catalog, file viewer, terminal, highlight + mermaid all
present, no machine-specific paths (xz-compressed, so smaller than the plain release). Windows
targets also need `7z`/`7zz` on `PATH`.

> **⚠️ Burrito caches the wrapped payload** at `~/Library/Application Support/.burrito/<app>_erts-<erts>_<version>`,
> keyed by app + ERTS + **version**. If you rebuild after changing code **without** bumping `version`
> in `mix.exs`, Burrito silently **reuses the stale payload** and the binary ships OLD code (the
> assembled `_build/prod/rel/<app>` is correct but ignored — symptom: the binary serves an older UI
> than `mix phx.server` does). Before a release rebuild, **bump the version** (or
> `rm -rf "$HOME/Library/Application Support/.burrito"`). Gotcha: `rm ~/…/.burrito/*` can silently
> no-op under zsh `nomatch` when a sibling glob is empty — delete the **directory**, not a `*` glob.
>
> Also `rm -rf _build/prod/rel/<app>` before the release: `mix release --overwrite` keeps OLD
> version dirs (`lib/jc-0.1.0`, `jc-0.2.0`, …) alongside the new one, which bloats the binary and
> makes `find … -name '*.beam' | head -1` pick a STALE version dir (false "fix missing" readings —
> always grep the specific `jc-<current>` dir). The release boots only `jc-<current>`, but ship clean.

Caveats: external backends (**ollama** / **claude-code-acp**) are still user-installed; live agent
recompile (🤖 Agents → Save) needs an `escript` available (system Erlang, or the bundled ERTS escript) —
the **pre-built agents load fine without it**. Next: `mix desktop.deploy`
([elixir-desktop](https://github.com/elixir-desktop/desktop)) for a native window; a Homebrew tap.

## Status

The full app is committed here and runs today: **parallel** threads, each on its own agent
(a local model **or** an ACP agent **or** the native Claude CLI); thread + conversation
**persistence** across reloads and restarts (a turn in flight **survives a reload**); interactive
**🔐 approvals**; **graceful stop/cancel** (the turn ends, partial output + token/cost badge land,
and the **agent + session survive** for the next message); **token/cost metering** (per-reply badge
+ per-thread `Σ` total + trace durations); a no-code **agent builder** + **Settings** (auto-detects
local models); a file viewer/editor; an embedded **terminal** (resizes with the pane); markdown +
mermaid rendering; dark/light themes; completion **notifications**; and a parallel-threads **board**.

Caveat: the node cwd is global, so a turn's project folder is set per turn (`File.cd!`); for true
concurrent isolation give a thread its own **git worktree** (the 🌳 button). External backends
(Ollama / `claude-code-acp` / the `claude` CLI) are user-installed. Follow-ups: a native desktop
window via [`elixir-desktop`](https://github.com/elixir-desktop/desktop); a Homebrew tap.
