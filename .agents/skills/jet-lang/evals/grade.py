#!/usr/bin/env python3
"""Grade the jet-lang skill A/B runs objectively: compile the produced .jet, drive it with OUR
own driver (never the agent's self-reported output), and grep the source for the mechanisms the
assertions name. Writes grading.json into each run directory."""
import json, os, re, shutil, subprocess, sys, tempfile

JET = "/Users/i2y/jet/jet"
ROOT = os.path.dirname(os.path.abspath(__file__))
IT = os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else "iteration-1")


def run(cmd, cwd=None, timeout=180):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def find(outdir, name):
    for base, _, files in os.walk(outdir):
        if name in files:
            return os.path.join(base, name)
    return None


def sandbox(src_path, extra=None):
    """Copy the produced file (plus an optional driver) into a scratch dir so grading never
    touches the agent's outputs and never reuses a stale .beam."""
    d = tempfile.mkdtemp()
    shutil.copy(src_path, d)
    if extra:
        name, body = extra
        with open(os.path.join(d, name), "w") as f:
            f.write(body)
    return d


def compiles(path):
    d = sandbox(path)
    rc, out = run([JET, os.path.join(d, os.path.basename(path))])
    shutil.rmtree(d, ignore_errors=True)
    return rc == 0, out.strip().splitlines()[0] if out.strip() else "clean"


CONS = re.compile(r"\[[^\]\n]*[A-Za-z_)\]}\s]\|[^\]\n|]*\]")   # [h | rest], not a lambda {|x|
BARE_IS = re.compile(r"(?<![:\w])is_(list|map|binary|atom|tuple|integer|float|number|pid|function)\s*\(")


def grade_eval1(outdir):
    a = []
    p = find(outdir, "cfg.jet")
    if not p:
        return [{"text": "cfg.jet exists", "passed": False, "evidence": "not produced"}]
    ok, ev = compiles(p)
    a.append({"text": "A1 cfg.jet compiles", "passed": ok, "evidence": ev})
    driver = ("drv.jet",
              'module drv\n  def self.run()\n'
              '    io::format("~p~n", [cfg::summarize(<<"{\\"name\\":null,\\"retries\\":7}">>)])\n'
              '    io::format("~p~n", [cfg::summarize(<<"{\\"name\\":\\"api\\",\\"tags\\":[\\"a\\",\\"b\\"]}">>)])\n'
              '  end\nend\n')
    d = sandbox(p, driver)
    run([JET, os.path.join(d, "cfg.jet")])
    rc, out = run([JET, "-r", "drv::run", os.path.join(d, "drv.jet")])
    shutil.rmtree(d, ignore_errors=True)
    lines = [l.strip() for l in out.splitlines() if l.strip().startswith("#{")]
    first, second = (lines + ["", ""])[:2]
    a.append({"text": 'A2 DISCRIMINATING: a JSON null name yields <<"unnamed">>, not the atom null',
              "passed": 'unnamed' in first and 'null' not in first,
              "evidence": first or out.strip()[:200]})
    a.append({"text": "A3 retries 7 kept, missing tags defaults to []",
              "passed": "7" in first and re.search(r"tags => \[\]", first) is not None,
              "evidence": first or "no output"})
    a.append({"text": 'A4 second input: name <<"api">>, retries 3, tags [<<"a">>,<<"b">>]',
              "passed": all(s in second for s in ['"api"', "3", '"a"', '"b"']),
              "evidence": second or "no output"})
    a.append({"text": "A5 result keys are the atoms name/retries/tags",
              "passed": all(f"{k} =>" in first for k in ("name", "retries", "tags"))
                        and "unknown" not in first,
              "evidence": first or "no output"})
    src = open(p).read()
    m = CONS.search(src)
    a.append({"text": "A6 no [x | rest] cons pattern", "passed": m is None,
              "evidence": m.group(0) if m else "none found"})
    return a


def grade_eval2(outdir):
    a = []
    p = find(outdir, "reviewer.jet")
    if not p:
        return [{"text": "reviewer.jet exists", "passed": False, "evidence": "not produced"}]
    ok, ev = compiles(p)
    a.append({"text": "B1 reviewer.jet compiles", "passed": ok, "evidence": ev})
    src = open(p).read()

    def has(pat, label, disc=""):
        m = re.search(pat, src)
        a.append({"text": label, "passed": m is not None,
                  "evidence": m.group(0).strip() if m else "absent"})

    has(r'drives\s+"claude-code-acp"|runner\s+Acp\s*\(', "B2 drives claude-code-acp")
    has(r'workspace\s+"\./src"', 'B3 workspace "./src"')
    has(r'(expose|ask|task)\s+review\s*\([^)]*\)\s*->', "B4 expose review(diff) is typed")
    has(r"enum\s*\(", "B5 DISCRIMINATING: severity uses enum(...)")
    # Two valid declaration forms: `tool name(args), "desc" do |x| … end`, and
    # `tools name` paired with `tool def name(args) … end`. Accept either.
    has(r"tool\s+\w+\s*\([^)]*\)[^\n]*\bdo\b|tool\s+def\s+\w+\s*\(", "B6 a tool with a body")
    m_ok = re.search(r"def\s+on_approval\s*\(", src)
    m_bad = re.search(r"\bapprove\s+do\b", src)
    a.append({"text": "B7 DISCRIMINATING: policy is def on_approval(req), not the removed `approve do`",
              "passed": m_ok is not None and m_bad is None,
              "evidence": (m_ok.group(0) if m_ok else "no on_approval") +
                          ("; ALSO uses removed `approve do`" if m_bad else "")})
    return a


def grade_eval3(outdir):
    a = []
    p = find(outdir, "stats.jet")
    if not p:
        return [{"text": "stats.jet exists", "passed": False, "evidence": "not produced"}]
    ok, ev = compiles(p)
    a.append({"text": "C1 stats.jet compiles", "passed": ok, "evidence": ev})
    src = open(p).read()
    m = re.search(r"def\s+initialize\s*\(", src)
    a.append({"text": "C2 DISCRIMINATING: the actor declares an explicit def initialize()",
              "passed": m is not None, "evidence": m.group(0) if m else "absent"})
    driver = ("drv3.jet",
              'module drv3\n  def self.run()\n'
              '    s = stats::Stats.spawn()\n'
              '    io::format("count=~p~n", [s.add(10)])\n'
              '    s.add(20)\n'
              '    s.add(30)\n'
              '    io::format("mean=~p~n", [s.mean()])\n'
              '    s.reset()\n'
              '    io::format("after_reset=~p~n", [s.mean()])\n'
              '  end\nend\n')
    d = sandbox(p, driver)
    run([JET, os.path.join(d, "stats.jet")])
    rc, out = run([JET, "-r", "drv3::run", os.path.join(d, "drv3.jet")])
    shutil.rmtree(d, ignore_errors=True)
    mean = re.search(r"mean=([\d.]+)", out)
    a.append({"text": "C3 mean of 10,20,30 is 20",
              "passed": mean is not None and abs(float(mean.group(1)) - 20.0) < 1e-6,
              "evidence": mean.group(0) if mean else out.strip()[:200]})
    ar = re.search(r"after_reset=\S+", out)
    a.append({"text": "C4 after reset, mean is :none",
              "passed": re.search(r"after_reset=none", out) is not None,
              "evidence": ar.group(0) if ar else (out.strip()[:200] or "no output")})
    cnt = re.search(r"count=(\d+)", out)
    a.append({"text": "C5 add returns the running count",
              "passed": cnt is not None and cnt.group(1) == "1",
              "evidence": cnt.group(0) if cnt else out.strip()[:200]})
    m = re.search(r"def\s+on_message\s*\(", src)
    a.append({"text": "C6 an on_message callback exists", "passed": m is not None,
              "evidence": m.group(0) if m else "absent"})
    m = CONS.search(src)
    a.append({"text": "C7 no [x | rest] cons pattern", "passed": m is None,
              "evidence": m.group(0) if m else "none found"})
    bare = [x.group(0) for x in BARE_IS.finditer(src)]
    a.append({"text": "C8 DISCRIMINATING: is_* outside a guard is erlang::-qualified",
              "passed": not bare, "evidence": ", ".join(bare) if bare else "no bare is_* calls"})
    return a


GRADERS = {1: grade_eval1, 2: grade_eval2, 3: grade_eval3}

if __name__ == "__main__":
    summary = {}
    for eid, fn in GRADERS.items():
        for arm in ("with_skill", "without_skill"):
            outdir = os.path.join(IT, f"eval-{eid}", arm, "outputs")
            if not os.path.isdir(outdir):
                continue
            res = fn(outdir)
            gp = os.path.join(IT, f"eval-{eid}", arm, "grading.json")
            with open(gp, "w") as f:
                json.dump({"expectations": res}, f, indent=2)
            p = sum(1 for r in res if r["passed"])
            summary.setdefault(arm, []).append((eid, p, len(res)))
            print(f"eval-{eid} {arm:14s} {p}/{len(res)}")
            for r in res:
                if not r["passed"]:
                    print(f"    FAIL {r['text']}\n         -> {r['evidence']}")
    print()
    for arm, rows in summary.items():
        p = sum(r[1] for r in rows); t = sum(r[2] for r in rows)
        print(f"{arm:14s} {p}/{t}  ({100.0*p/t:.0f}%)")
