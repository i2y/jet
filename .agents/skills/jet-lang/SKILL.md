---
name: jet-lang
description: >-
  Write, fix, or review Jet code (`.jet` files) — a dynamically typed, Ruby-syntax language that
  compiles to BEAM/Erlang bytecode, where `class`, `actor` and `agent` are all first-class forms
  and `x.method()` spans all three. Use this whenever a file ends in `.jet`, whenever `jet`,
  `jet build`, `jet acp-serve` or `jet mcp-serve` appears, and whenever the task mentions Jet
  agents, runners (Llm/Acp/Fleet/Pipeline/Refine/Debate/Goal/Flow/Architect), `expose`, `drives`,
  or a `jet_*` stdlib module. Reach for this even when the code looks like Ruby or Elixir you
  already know: Jet is almost certainly not in your training data, and the parts that differ are
  exactly the parts that will silently bite.
---

# Writing Jet

Jet looks like Ruby and runs on the Erlang VM. That combination is the trap: your instincts come
from two languages, and Jet is neither. Almost every mistake below is code that *reads* correctly.

## Compile after every edit — this is the whole method

```sh
./jet path/to/File.jet                  # compile; writes File.beam next to it
./jet -r Module::func path/to/File.jet  # compile and run one function
./jet build src/                         # compile a directory
```

The compiler is the only authority on Jet syntax — not your priors, and not this document.
It is fast and its errors name the line, so the productive loop is write a little, compile, repeat.
Do not write a hundred lines and then compile once; a single early misconception (say, how `nil`
works) will have propagated everywhere by then.

Two things about the errors: a parse error is reported at the **line where the parser gave up**,
which is often the line *after* the real mistake, and a reserved word used as a name is frequently
blamed on the enclosing `def`. When an error makes no sense, suspect the token just before it.

## Traps that compile fine and then do the wrong thing

These are the expensive ones, because no error ever appears. Each is pinned by a probe in
`probes/value/`.

**A string literal as a map key silently becomes the atom `unknown`.**

```jet
{"gen_ai.system": v}                             # => #{unknown => 1}   WRONG, and silent
maps::from_list([{<<"gen_ai.system">>, v}])      # => #{<<"gen_ai.system">> => 1}
{system: v}                                      # => #{system => 1}    atom key
```

Map-literal keys are for atoms only. Dotted or otherwise non-atom keys must go through
`maps::from_list` with explicit binaries.

**`nil` is the empty list, and JSON `null` is not it.**

```jet
nil == []          # true  — `nil` in Jet source IS []
nil == :nil        # false — :nil is the atom
```

A JSON `null` decodes to the atom `null`, so `v == nil` **never** matches a decoded null. When
checking a decoded field, compare against `null` or use `maps::find`.

**`"..."` is a char list; `<<"...">>` is a binary.** They are never equal. Erlang/OTP functions
mostly want binaries; `erlang::iolist_to_binary` converts. A `to_bin` helper at the bottom of a
module is the local idiom.

**A parenthesised comma list is a tuple.** `(1, 2, 3)` is `{1,2,3}`, not a grouping.

**A plain `def` inside a module gets an implicit `self`, so it exports at arity + 1.**

```jet
def plain(x)         # exports as plain/2  — not callable as plain/1, invisible to `jet -r`
def self.plain(x)    # exports as plain/1  — what you meant
```

Module-level functions want `def self.`. Only methods inside a `class`/`actor`/`agent` want the
bare form, where the implicit `self` is the point.

**Name the file after the module.** The `.beam` is named from the **source filename**, but the
module inside it is named by the `module` declaration — and BEAM's loader finds a module by looking
for `<module>.beam`. So `module Foo` in `bar.jet` compiles cleanly, produces `bar.beam`, and can
never be loaded: every call reports "a function was called but it did not exist".

## Traps that fail to compile

Faster to discover, so just know the fixes. Pinned by `probes/compile_fail/`.

| You write | What happens | Write instead |
|---|---|---|
| `[h \| rest]` | `illegal_pattern` — `\|` is the pipe operator | `[h, *rest]` |
| `erlang::raise(...)` | `raise` is reserved | `erlang::apply(:erlang, :raise, [c, r, st])` |
| `binary::match(...)` | `match` is reserved | `binary::split`, or `erlang::apply(:binary, :match, [...])` |
| `{agent: x}`, `def f(actor)` | `agent`/`actor` are reserved — also as map keys | any other name: `apid`, `member`, `turn_method` |
| `a div b` | not an operator | `erlang::div(a, b)` or `erlang::trunc(a / b)` |
| `if c do … end` | `if` takes no `do` — it fails with or without an `else` | drop the `do`: `if c` / body / `else` / body / `end`, which **is** an expression and can be assigned |
| `module A` inside `module B` | not supported | one module per file |
| `case p when guard` | `when` is not a keyword here — it parses as a variable, then `unbound_var 'When'` | `case p if guard` |
| `enum("low", "high")` | `expected an atom value in enum(...), got string` | `enum(:low, :high)` |
| `Thing.spawn()` unqualified | `unbound_var 'Thing'` — a class/actor/agent name is not a bare variable | `mod::Thing.spawn()`, **even inside `mod` itself** |

Two of those are Erlang/Elixir reflexes, which is why they are worth naming: `when` for a guard, and
strings where Jet wants atoms. A model's `"high"` **is** accepted at run time and coerced to the atom
— it is only the *schema declaration* that must be written with atoms.

An **`actor` needs an explicit `def initialize()`**; only `agent` gets one synthesised. Without it,
`spawn()` dies with `bad key: {initialize,0}`.

Inside an actor method, the common BIFs (`element`, `length`, `hd`, `tl`, `integer_to_list`, …)
work bare — `Kernel.jet` wraps them. The **`is_*` type tests do not**: they were left unwrapped so
they don't shadow the guard BIFs, so in an expression position `if is_list(x)` dispatches as a
method and dies with `method_missing`. Write `erlang::is_list(x)` anywhere that isn't a guard.

## Do not defend against these — they are fixed

Stale advice about Jet is in circulation, and writing around a trap that no longer exists costs
clarity for nothing. Each of these is pinned by a probe in `probes/compile_ok/`:

- **`not` binds tighter than `and`/`or`.** `not x and not y` is `(not x) and (not y)`. Don't add
  parens defensively.
- **A newline right after `(` is fine** — in call arguments, `def` parameters, tuples, conditions.
- `[h, *rest]` is the list pattern and it works. Only the `|` form is broken.

If you believe you've hit one of these, add a probe and prove it before writing around it.

## A file that compiles

```jet
module weather
  agent Forecaster
    model "ollama:qwen3.6:35b-a3b"          # or: drives "claude-code-acp"
    role "You report the weather plainly."
    tool lookup(city: String), "Current conditions for a city" do |c|
      <<"sunny, 22C">>
    end
    expose report(city) -> {summary: String, celsius: Int}
  end

  def self.run()
    f = weather::Forecaster.spawn()
    match f.report("Kyoto").await()
      case {:ok, r}
        io::format("~ts (~p C)~n", [maps::get(:summary, r), maps::get(:celsius, r)])
      case {:error, reason}
        io::format("failed: ~p~n", [reason])
    end
  end
end
```

Points worth internalising: an exposed method's call is **async** and returns a future, so it needs
`.await()` (or `.stream do |ev|`). The declared `-> Type` is a **contract**, not a hint — a reply
that cannot satisfy it comes back as `{:error, {:schema_mismatch, …}}`, never as raw text, so
always match on the result rather than assuming success. `@attr` inside a method is instance state.

## Where to look next

Load these only when the task needs them — they are longer and they change more often than the
traps above.

- **`references/agents.md`** — the `agent` DSL in full: runners and backends, `expose` return types,
  tools, memory, skills, MCP servers, the collaboration shapes (Fleet/Pipeline/Refine/Debate/Goal/
  Flow/Architect), and serving an agent over ACP or MCP.
- **`references/language.md`** — the rest of the language: classes, actors, pattern matching,
  `try`/`catch`, operators, and calling Erlang/OTP.

In a Jet checkout, `README.md` is the argument for the language, `docs/` is the depth, and `src/`
is the standard library **written in Jet itself** — when you need to know how something really
behaves, read the module that does it.

## Keeping this file honest

Every factual claim above has a probe. Run them against the compiler you actually have:

```sh
.agents/skills/jet-lang/probes/run.sh
```

31 probes, four kinds: must-not-compile (the trap is real), must-compile (the trap was fixed),
must-print-its-`.expected` (the silent traps), and compiles-but-fails-at-run-time. A failure means
a sentence here has become false — **fix the prose, not the probe**. If you discover a new trap,
add a probe with it, so the next reader gets a claim that is checked rather than remembered.
