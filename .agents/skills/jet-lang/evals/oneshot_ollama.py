#!/usr/bin/env python3
"""One-shot generation on a LOCAL model, with and without the skill in the system prompt.

This is deliberately a DIFFERENT experiment from the agentic A/B. There is no compiler in the
loop: the model gets one attempt and never sees an error message. The agentic runs let the
compiler do much of the work — a model that knows nothing can still converge by trial and error,
which is why the Opus arms tied. One-shot isolates what the skill is actually for: the model's
PRIORS about a language absent from its training data.

The with-skill arm gets SKILL.md's body as the system prompt. It does NOT get references/, since
those are level-3 progressive disclosure that a one-shot call cannot ask for.

Usage: oneshot_ollama.py <model> <samples-per-task> <out-dir>
"""
import os

# Resolve the repo (and so the compiler) from THIS file's location, or from $JET. Hardcoding an
# author's absolute path into a script that ships in the repo makes it useless to everyone else.
_REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4))
JET = os.environ.get("JET", os.path.join(_REPO, "jet"))
SKILL = os.environ.get("JET_SKILL", os.path.join(_REPO, ".agents", "skills", "jet-lang", "SKILL.md"))

import json, os, re, shutil, subprocess, sys, tempfile, urllib.request

OLLAMA = "http://localhost:11434/api/chat"

BASE_SYS = ("You write Jet, a dynamically typed language with Ruby-like syntax that compiles to "
            "BEAM/Erlang bytecode. Reply with the complete contents of the requested .jet file in a "
            "single ```jet code block, and nothing else.")

TASKS = {
    "cfg": ("cfg.jet",
            'Write a Jet module called `cfg` in cfg.jet with one function `summarize(json_binary)` '
            'that decodes the JSON and returns a map with three atom keys: `name` (a binary; use '
            '<<"unnamed">> when the field is missing or null), `retries` (an integer; use 3 when '
            'missing or null), and `tags` (a list; use [] when missing or null). Optional fields come '
            'back as JSON null rather than being left out. Decode with jet_json_ffi::decode(binary), '
            'which returns {:ok, map} with binary keys.'),
    "reviewer": ("reviewer.jet",
            'Write a Jet agent file, reviewer.jet, for a code reviewer. It should drive the external '
            'claude-code-acp agent, sandbox itself to ./src, and expose a review(diff) method that '
            'returns a typed result: a summary string, a list of issue strings, and a severity that '
            'has to be one of low, medium or high. Give it a tool that runs a shell command too, and '
            'a permission policy that denies anything that executes.'),
    "stats": ("stats.jet",
            'Write a Jet actor in stats.jet called Stats that accumulates numbers. add(n) records n '
            'and returns how many have been recorded so far; mean() returns the average, or :none '
            'when nothing has been recorded; reset() clears it. It also needs to survive being sent '
            'a plain message without dying. Also add a module-level function that demonstrates it: '
            'add 10, 20 and 30, print the mean, reset, then print the mean again.'),
}


def chat(model, system, user):
    body = json.dumps({"model": model, "stream": False, "options": {"temperature": 0.2},
                       "messages": [{"role": "system", "content": system},
                                    {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(OLLAMA, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)["message"]["content"]


FENCE = re.compile(r"```(?:jet|ruby|elixir|erlang)?\s*\n(.*?)```", re.S)


def extract(reply):
    blocks = FENCE.findall(reply)
    if blocks:
        return max(blocks, key=len).strip()
    # no fence: strip a leading <think> block some models emit, then take the rest
    return re.sub(r"<think>.*?</think>", "", reply, flags=re.S).strip()


def compiles(path):
    d = tempfile.mkdtemp()
    shutil.copy(path, d)
    p = subprocess.run([JET, os.path.join(d, os.path.basename(path))],
                       capture_output=True, text=True)
    shutil.rmtree(d, ignore_errors=True)
    return p.returncode == 0, (p.stdout + p.stderr).strip().splitlines()[:1]


if __name__ == "__main__":
    model, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with_sys = BASE_SYS + "\n\n--- Jet reference ---\n" + open(SKILL).read()
    arms = {"with_skill": with_sys, "without_skill": BASE_SYS}
    tally = {}
    for arm, sys_prompt in arms.items():
        for task, (fname, prompt) in TASKS.items():
            for i in range(n):
                d = os.path.join(out, arm, task, f"sample-{i}")
                os.makedirs(d, exist_ok=True)
                dst = os.path.join(d, fname)
                if not os.path.exists(dst):
                    try:
                        reply = chat(model, sys_prompt, prompt)
                    except Exception as e:
                        reply = f"REQUEST FAILED: {e}"
                    open(os.path.join(d, "raw.txt"), "w").write(reply)
                    open(dst, "w").write(extract(reply))
                ok, err = compiles(dst)
                tally.setdefault(arm, []).append((task, i, ok, err))
                print(f"  {arm:14} {task:9} #{i}  {'COMPILES' if ok else 'fails   '}"
                      f"  {'' if ok else (err[0][:88] if err else '')}", flush=True)
    print()
    for arm, rows in tally.items():
        c = sum(1 for r in rows if r[2])
        print(f"{arm:14} compiles {c}/{len(rows)}  ({100.0*c/len(rows):.0f}%)")
    json.dump({a: [{"task": t, "sample": i, "compiles": ok} for t, i, ok, _ in rows]
               for a, rows in tally.items()}, open(os.path.join(out, "summary.json"), "w"), indent=2)
