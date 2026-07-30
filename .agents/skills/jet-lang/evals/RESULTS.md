# Does the skill actually help? — measured, 2026-07-30

The probes in `probes/` verify the skill is **true**. They say nothing about whether it makes an
agent better. This is the A/B that measures that, and the honest headline is: **it does not change
whether the agent succeeds — it changes what the success costs, and what the code looks like.**

## Method

Three realistic tasks, each aimed at a different part of Jet, run by an identical coding agent
(Claude Opus, max reasoning) with and without the skill. Both arms got the compiler and were barred
from reading Jet's standard library, README and docs — because the deployment this skill exists for
is writing `.jet` files **outside** a Jet checkout. Grading never trusts the agent's self-report:
`evals/../grade.py` recompiles each artifact and drives it with its own driver.

| Task | Aimed at |
|---|---|
| `json-null-config` | JSON `null` is the atom `null`; Jet's `nil` is `[]`; char list vs binary |
| `agent-dsl-reviewer` | the `agent` DSL: `expose` + schema, `enum`, tools, `on_approval` |
| `actor-stats` | `actor` needs an explicit `initialize`; `@attr`; list handling |

## Correctness: a draw

```
iteration 1  with skill     21/21  (100%)
iteration 1  no skill       20/21  ( 95%)
iteration 2  with skill     21/21  (100%)
```

The single miss was an omitted `on_message`, and even that is a strict reading — the baseline's
actor does survive a bare message, because the runtime ignores off-protocol messages anyway.

**All three traps the tasks were built around were found by the baseline unaided.** Given a
compiler and the patience to probe it, a strong model reaches the truth on its own. Any claim that
this skill is required to write working Jet would be false.

(One grader bug was found and fixed while scoring: an assertion missed the valid
`tool def name(...)` declaration form and scored the baseline 19/21. The corrected figure is above.)

## Cost: a large difference

| | with skill | no skill | ratio |
|---|---|---|---|
| json-null-config | 40,663 tok / 139 s | 50,584 tok / 391 s | 1.2× / 2.8× |
| agent-dsl-reviewer | 55,074 tok / 296 s | **130,683 tok / 1,369 s** | **2.4× / 4.6×** |
| actor-stats | 40,235 tok / 162 s | 56,498 tok / 450 s | 1.4× / 2.8× |
| **total** | **135,972 tok / 10 min** | **237,765 tok / 37 min** | **1.75× / 3.7×** |

43% fewer tokens, 73% less wall time, for the same result. The gap widens with the task's distance
from general programming knowledge: the `agent` DSL, which nothing in a model's training data
resembles, cost the baseline 2.4× the tokens and 4.6× the time.

## Quality the compiler cannot see

Both `actor-stats` arms pass every assertion. They do not look alike:

```
with skill   actor Stats                 stats::Stats.spawn()
no skill     class Stats + meta Actor    Stats().spawn()
```

`class` + `meta Actor` is the form `actor` desugars to, and `Stats()` is a workaround for not
knowing that a class name needs its module prefix. Both compile, both pass, and a maintainer
inherits the internals instead of the language.

## What iteration 2 actually bought

Not a better score — iteration 1 was already at 100% and iteration 2's cost was flat
(135,244 tok / 589 s, within noise of 135,972 / 597 despite a ~20% longer skill). What it bought
was **five new verified traps** and, more valuably, **two corrections to the skill's own prose**:

- The `if` row misattributed the cause. It read as though *inline-ness* were the problem; the
  parser actually rejects the `do`, with or without an `else`, and the block form **is** an
  assignable expression. Both forms are now pinned (`compile_fail/if_with_do.jet`,
  `compile_ok/if_as_expression.jet`).
- The `on_approval` example in `references/agents.md` was **silently broken in the general case**.
  It matched `case "execute"`, which works for an ACP request (a char list) but never fired for the
  native tool gate (a binary) — a policy that gates nothing.

  That one turned out to be a bug in Jet rather than in the skill, and it was fixed at the root:
  `jet_policy::request` is now the single place a permission request is shaped, and a `tool` can
  declare `, :kind`. So the documented policy works on both paths, and an undeclared tool reports
  `"other"` instead of a blanket `"execute"`. Pinned by `value/approval_request_agrees.jet` and
  `value/documented_policy_gates.jet`.

  Worth recording how nearly that was missed: the first probe written for it compared *literals*
  (`erlang::is_binary(<<"execute">>)`), which is a tautology — it passed before and after the fix.
  A probe that cannot fail is not evidence. It now calls both builders and compares them.

That is the loop earning its keep: the eval found defects in the skill, not just gaps in it.

## Three model tiers, and the result reverses

The measurement above used one model (Claude Opus, max reasoning). Repeating it down the capability
range is what actually located the skill's value — and showed that the first round had been measuring
the least informative case.

| | with skill | no skill |
|---|---|---|
| **Opus**, agentic (compiler in the loop) | 21/21 (100%) | 20/21 (95%) |
| **Haiku 4.5**, agentic (compiler in the loop) | 20/21 (95%) | **7/21 (33%)** |
| **qwen3.6:35b-a3b** (local), one-shot, no compiler | 2/9 compile (22%) | 0/9 compile (0%) |

Opus finds every trap unaided, so the skill only buys it speed. Haiku does not: its unaided runs
produced a `cfg.beam` whose module was named `Cfg` and could never be loaded, a `reviewer.jet` with
no `drives`, no `workspace`, no typed `expose`, no `enum` and no tool, and a `Stats` the driver
couldn't reach — **all three reported as successes.** That is where a skill earns its place: not
making a capable model correct, but keeping a cheap one from shipping confident nonsense.

The local one-shot run is a different experiment: no compiler in the loop, one attempt, no error to
read. It isolates the model's PRIORS rather than its persistence, which is what a skill actually
changes. The honest reading is that 22% is not a usable success rate — at this tier the skill is not
enough — but the *shape* of the failures separates cleanly:

```
no skill     no `module` wrapper, `agent` at top level, `do` in a class body
             -> the skeleton isn't there
with skill   the skeleton is right; it dies on `+=`, on `||`, and on a `sandbox`
             declaration that doesn't exist
```

Every one of those with-skill failures was a hole in the skill, not in the model. It had never said
that Jet has **no `+=`, no `||`, no `&&`, no `!`** — the most basic Ruby-vs-Jet differences, each of
which kills a file on its own. Opus and Haiku both knew to write `or` and never reached for `+=`, so
six agentic runs across two tiers never once exposed it. **The skill had been calibrated, invisibly,
for strong models.** Now pinned by `compile_fail/ruby_operators.jet`,
`compile_fail/compound_assign.jet` and `compile_ok/word_operators.jet`, and the valid `agent` body
declarations are listed in SKILL.md so an invented `sandbox` has something to be checked against.

Reproduce the local run with `oneshot_ollama.py <model> <samples> <out-dir>`.

## Does the description trigger at all?

A skill that is never consulted is worth nothing regardless of its contents, and this went
unmeasured for the whole first round. Measured through the real mechanism — the skill installed at
`<project>/.claude/skills/jet-lang/`, a plain `claude -p` from that project, and a verdict of
"triggered" only on an actual `Skill` tool call or a `Read` of its SKILL.md:

```
should trigger      3/3   cons-pattern question · write a worker.jet · a confusing :: error
should NOT trigger  2/2   a ruby memoize class · an erlang gen_server
```

The `worker.jet` run went on to read `references/language.md` by itself, which is progressive
disclosure working as designed.

Two earlier attempts at this number were wrong and are discarded. The skill-creator trigger harness
reported 0/10 on positives, but it resolves a project root by walking up for `.claude/` — started
from its own directory it landed on `$HOME` and registered the skill as a slash command there. Then
a hand-rolled replacement reported 0/3, because macOS has no GNU `timeout`: every invocation died
instantly with empty output, which reads exactly like "never triggered". A third pass grepped the
stream for the skill's name and counted the `available_skills` listing as an invocation, which
inverted the negatives.

The pattern is worth naming, because it is the same one three times: **a measurement that produces a
suspiciously clean result is more likely broken than decisive.** A perfect 0 on one whole class, a
tautological assertion that cannot fail, an all-passing grader — each looked like a finding and each
was a bug in the instrument. It is also, exactly, the argument for `probes/`.

## Limits of this measurement

- **n = 1 per cell.** Three tasks, one run each. The cost differences are large enough to survive
  a lot of noise; the 21/21 vs 20/21 difference is not.
- The baseline for `agent-dsl-reviewer` cites internal details (`jet_acp::workspace_root/1`,
  lowered schema shapes). It may have obtained them by runtime introspection, which was permitted,
  or by reading source, which was not — the constraint was instructed, not enforced. Either way it
  still spent 2.4× the tokens.
- Only iteration 2's with-skill arm was re-run; the baseline does not change when the skill does, so
  re-running it would have measured run-to-run variance rather than anything about the skill.
- The Haiku and local runs used the skill as it stood *before* the Ruby-operator traps were added.
  Re-running the local one-shot would very likely score higher now — that number is not claimed here.
- The trigger check is 5 queries, not the 20 the eval set holds; it was run by hand after the
  automated harness proved unreliable.

Reproduce with `grade.py <iteration-dir>`; the run artifacts are not committed.
