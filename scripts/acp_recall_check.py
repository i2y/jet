#!/usr/bin/env python3
# Hermetic end-to-end check of the ACP server's conversation memory (the 1c unification:
# the server OWNS per-session memory via jet_memory; server-driven agents defer their own).
# Drives `./jet acp-serve` over real stdio JSON-RPC -- a programmatic substitute for a
# manual ACP-client session -- and asserts that turn 2 recalls what turn 1 said.
#
#   python3 scripts/acp_recall_check.py        (run from the repo root; needs ollama)
#
# Exit 0 = recall worked (+ a per-session snapshot was persisted); exit 1 = it did not.
import json, subprocess, sys, os

env = dict(os.environ, JET_ACP_SESSIONS_DIR="/tmp/jet_acp_1c")
os.system("rm -rf /tmp/jet_acp_1c")
p = subprocess.Popen(
    ["./jet", "acp-serve", "agent_memory_demo::Assistant::chat", "examples/agent_memory_demo.jet"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, bufsize=1, text=True)

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def pump_until(wid, collect=False):
    # read until a response with id==wid; meanwhile collect agent_message_chunk text
    buf = []
    while True:
        line = p.stdout.readline()
        if not line:
            return None, "".join(buf)
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if collect and m.get("method") == "session/update":
            u = m.get("params", {}).get("update", {})
            if u.get("sessionUpdate") == "agent_message_chunk":
                buf.append(u.get("content", {}).get("text", ""))
        if m.get("id") == wid and ("result" in m or "error" in m):
            return m, "".join(buf)

def prompt(i, sid, text, collect=False):
    send({"jsonrpc": "2.0", "id": i, "method": "session/prompt",
          "params": {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}})
    return pump_until(i, collect)

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}}); pump_until(1)
send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {}})
r, _ = pump_until(2); sid = r["result"]["sessionId"]; print("sessionId:", sid)

prompt(3, sid, "My name is Ada and my favorite number is 42. Acknowledge briefly.")
_, txt = prompt(4, sid, "What is my name and my favorite number?", collect=True)
print("turn 2 agent text:", txt.strip()[:300])

ok = ("Ada" in txt) and ("42" in txt)
snap = os.path.exists(f"/tmp/jet_acp_1c/{sid}.json")
print("RECALL OK (server-owned memory over the real ACP protocol):", ok)
print("snapshot persisted:", snap)
p.stdin.close(); p.terminate()
sys.exit(0 if (ok and snap) else 1)
