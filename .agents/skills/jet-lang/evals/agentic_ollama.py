#!/usr/bin/env python3
"""A local model WITH the compiler in the loop — the cell the other two tiers already have.

The one-shot run measured priors. This measures what someone actually does: generate, compile,
read the error, fix, repeat. That is the setting where a skill's cost benefit exists at all, since
the saving comes from avoided attempts rather than from a shorter prompt.

Records, per task and arm: attempts used, whether it ever compiled, ollama's own prompt/eval token
counts summed across attempts, and wall time. Outputs land where grade.py can score them.

Usage: agentic_ollama.py <model> <max-attempts> <out-dir>
"""
import os

# Resolve the repo (and so the compiler) from THIS file's location, or from $JET. Hardcoding an
# author's absolute path into a script that ships in the repo makes it useless to everyone else.
_REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4))
JET = os.environ.get("JET", os.path.join(_REPO, "jet"))
SKILL = os.environ.get("JET_SKILL", os.path.join(_REPO, ".agents", "skills", "jet-lang", "SKILL.md"))

import json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

OLLAMA = "http://localhost:11434/api/chat"

BASE_SYS = ("You write Jet, a dynamically typed language with Ruby-like syntax that compiles to "
            "BEAM/Erlang bytecode. Always reply with the COMPLETE contents of the requested .jet "
            "file in a single ```jet code block, and nothing else — never a fragment or a diff.")

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
            'a plain message without dying. Also add a module-level function `run` that demonstrates '
            'it: add 10, 20 and 30, print the mean, reset, then print the mean again.'),
}

FENCE = re.compile(r"```(?:jet|ruby|elixir|erlang)?\s*\n(.*?)```", re.S)


def extract(reply):
    b = FENCE.findall(reply)
    if b:
        return max(b, key=len).strip()
    return re.sub(r"<think>.*?</think>", "", reply, flags=re.S).strip()


def chat(model, messages):
    body = json.dumps({"model": model, "stream": False, "options": {"temperature": 0.2},
                       "messages": messages}).encode()
    req = urllib.request.Request(OLLAMA, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=1200) as r:
        d = json.load(r)
    return d["message"]["content"], d.get("prompt_eval_count", 0), d.get("eval_count", 0)


def compile_err(path):
    """Compile a COPY, so a stale .beam never makes a broken file look fine."""
    d = tempfile.mkdtemp()
    shutil.copy(path, d)
    p = subprocess.run([JET, os.path.join(d, os.path.basename(path))], capture_output=True, text=True)
    shutil.rmtree(d, ignore_errors=True)
    return (p.returncode == 0), (p.stdout + p.stderr).strip()


def run_task(model, sys_prompt, task, fname, prompt, outdir, max_attempts):
    os.makedirs(outdir, exist_ok=True)
    dst = os.path.join(outdir, fname)
    msgs = [{"role": "system", "content": sys_prompt}, {"role": "user", "content": prompt}]
    ptok = etok = 0
    t0 = time.time()
    for attempt in range(1, max_attempts + 1):
        reply, p, e = chat(model, msgs)
        ptok += p; etok += e
        open(dst, "w").write(extract(reply))
        ok, err = compile_err(dst)
        if ok:
            return {"attempts": attempt, "compiled": True, "prompt_tok": ptok,
                    "eval_tok": etok, "seconds": round(time.time() - t0, 1)}
        msgs.append({"role": "assistant", "content": reply})
        msgs.append({"role": "user", "content":
                     f"That does not compile. The Jet compiler said:\n\n{err[:1200]}\n\n"
                     f"Fix it and reply with the complete corrected {fname} in one ```jet block."})
    return {"attempts": max_attempts, "compiled": False, "prompt_tok": ptok,
            "eval_tok": etok, "seconds": round(time.time() - t0, 1)}


if __name__ == "__main__":
    model, cap, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with_sys = BASE_SYS + "\n\n--- Jet reference ---\n" + open(SKILL).read()
    arms = {"with_skill": with_sys, "without_skill": BASE_SYS}
    res = {}
    for arm, sp in arms.items():
        for task, (fname, prompt) in TASKS.items():
            # laid out so grade.py can score it directly
            d = os.path.join(out, f"eval-{ {'cfg':1,'reviewer':2,'stats':3}[task] }", arm, "outputs")
            r = run_task(model, sp, task, fname, prompt, d, cap)
            res.setdefault(arm, {})[task] = r
            print(f"  {arm:14} {task:9} attempts={r['attempts']} "
                  f"{'COMPILED' if r['compiled'] else 'gave up'} "
                  f"{r['prompt_tok']+r['eval_tok']:>7,} tok  {r['seconds']:>6.0f} s", flush=True)
    print()
    for arm, tasks in res.items():
        tk = sum(t["prompt_tok"] + t["eval_tok"] for t in tasks.values())
        sec = sum(t["seconds"] for t in tasks.values())
        att = sum(t["attempts"] for t in tasks.values())
        c = sum(1 for t in tasks.values() if t["compiled"])
        print(f"{arm:14} compiled {c}/3   attempts {att}   {tk:,} tok   {sec:.0f} s")
    json.dump(res, open(os.path.join(out, "cost.json"), "w"), indent=2)
