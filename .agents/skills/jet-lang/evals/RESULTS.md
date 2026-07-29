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
  It matched `case "execute"`, which works for an ACP request (a char list) but never fires for the
  native tool gate (a binary) — a policy that gates nothing. Now pinned by
  `value/approval_kind_types.jet`, with a normalising helper in the reference.

That is the loop earning its keep: the eval found defects in the skill, not just gaps in it.

## Limits of this measurement

- **n = 1 per cell.** Three tasks, one run each. The cost differences are large enough to survive
  a lot of noise; the 21/21 vs 20/21 difference is not.
- The baseline for `agent-dsl-reviewer` cites internal details (`jet_acp::workspace_root/1`,
  lowered schema shapes). It may have obtained them by runtime introspection, which was permitted,
  or by reading source, which was not — the constraint was instructed, not enforced. Either way it
  still spent 2.4× the tokens.
- Only iteration 2's with-skill arm was re-run; the baseline does not change when the skill does, so
  re-running it would have measured run-to-run variance rather than anything about the skill.

Reproduce with `grade.py <iteration-dir>`; the run artifacts are not committed.
