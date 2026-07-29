# jet-lang — an Agent Skill for writing Jet

An [Agent Skill](https://code.claude.com/docs/en/skills) that teaches a coding agent to write Jet
that actually compiles. It exists because of one blunt fact: Jet is new, so it is essentially absent
from every model's training data — and because Jet *looks* like Ruby, an agent will confidently write
Ruby-shaped code that the compiler rejects, or worse, code that compiles and quietly does the wrong
thing.

```
SKILL.md              the verified traps, and the compile-after-every-edit loop
references/
  agents.md           the `agent` DSL: runners, expose, shapes, serving over ACP/MCP
  language.md         classes, actors, matching, errors, Erlang interop, building
probes/
  run.sh              checks every claim SKILL.md makes against your compiler
  compile_fail/       these must NOT compile          (the trap is real)
  compile_ok/         these must compile              (the trap was fixed — don't work around it)
  value/              these must print their .expected (silent traps; compiling can't catch them)
  run_fail/           these compile but must fail at run time
```

## Install it

The skill is a directory; putting it where your tool looks is the whole installation.

```sh
# a project you're writing .jet files in — vendor-neutral location
mkdir -p .agents/skills && cp -R /path/to/jet/.agents/skills/jet-lang .agents/skills/

# Claude Code, per project or personally
mkdir -p .claude/skills   && cp -R /path/to/jet/.agents/skills/jet-lang .claude/skills/
mkdir -p ~/.claude/skills && cp -R /path/to/jet/.agents/skills/jet-lang ~/.claude/skills/
```

Inside a Jet checkout there is nothing to do: an agent working here already sees it, and so does
Jet's own runtime — `jet_skills` walks the working directory's ancestors looking for exactly
`.agents/skills` and `.claude/skills`, which means **a Jet agent can load this skill and write Jet**.

## Why the probes exist

Every language skill has the same failure mode: the language moves, the prose doesn't, and the skill
starts teaching syntax that stopped being true — with total confidence, which is worse than shipping
nothing. This is not hypothetical. The first draft of this skill was written from notes, and three of
its "gotchas" turned out to be false: two described traps that had already been fixed (so it told you
to write uglier code for no reason), and one had the mechanism backwards — a string literal as a map
key was recorded as a parse error, when in fact it compiles and silently yields the atom `unknown`,
which is the far more dangerous truth.

The probes are the fix. Jet is unusually well placed for this, because **compiling is the assertion**:

```sh
./probes/run.sh                 # or: ./probes/run.sh /path/to/jet
```

When a claim stops being true, the probe fails and names it. Fix the prose, not the probe. If you
find a new trap, add a probe with it — a checked claim ages better than a remembered one.
