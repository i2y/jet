// Cross-restart resume: store a turn, KILL the agent, start a FRESH process,
// session/load the same id -> verify history replays AND memory survived.
//   node examples/test_resume.js ./jet acp-serve acp_demo::Sage::reply examples/acp_demo.jet
const { spawn } = require('child_process');
const A = process.argv.slice(2);
function session(driver) {
  return new Promise((resolve) => {
    const child = spawn(A[0], A.slice(1), { stdio: ['pipe', 'pipe', 'inherit'] });
    const send = (o) => child.stdin.write(JSON.stringify(o) + '\n');
    const done = (v) => { child.kill(); setTimeout(() => resolve(v), 60); };
    let buf = '';
    child.stdout.on('data', (d) => { buf += d; let i;
      while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
        if (!l.trim()) continue; let m; try { m = JSON.parse(l); } catch { continue; } driver(m, send, done); } });
    setTimeout(() => send({ jsonrpc:"2.0", id:1, method:"initialize", params:{ protocolVersion:1, clientCapabilities:{} } }), 150);
  });
}
(async () => {
  const sid = await session((m, send, done) => {
    if (m.id === 1) send({ jsonrpc:"2.0", id:2, method:"session/new", params:{ cwd:".", mcpServers:[] } });
    else if (m.id === 2) { const s = m.result.sessionId;
      send({ jsonrpc:"2.0", id:3, method:"session/prompt", params:{ sessionId:s, prompt:[{ type:"text", text:"Remember the number 42. Just say OK." }] } }); m._s = s; global.S = s; }
    else if (m.id === 3) { console.log("[phase 1] stored a turn; sid=" + global.S); done(global.S); }
  });
  console.log("\n--- agent KILLED; starting a FRESH process, resuming " + sid + " ---\n");
  let replay = [], answer = "", loaded = false;
  await session((m, send, done) => {
    if (m.id === 1) send({ jsonrpc:"2.0", id:2, method:"session/load", params:{ sessionId:sid, cwd:".", mcpServers:[] } });
    else if (m.method === 'session/update') { const u = m.params.update, t = u.content && u.content.text;
      if (!loaded) { if (u.sessionUpdate === 'user_message_chunk') replay.push("USER: " + t);
        else if (u.sessionUpdate === 'agent_message_chunk') replay.push("ASST: " + t); }
      else if (u.sessionUpdate === 'agent_message_chunk') answer += t; }
    else if (m.id === 2) { loaded = true;
      console.log("[phase 2] session/load result =", JSON.stringify(m.result), "(must be a struct {}, not null)");
      console.log("[phase 2] replayed history:\n  " + (replay.join("\n  ") || "(none)"));
      send({ jsonrpc:"2.0", id:3, method:"session/prompt", params:{ sessionId:sid, prompt:[{ type:"text", text:"What number did I ask you to remember?" }] } }); }
    else if (m.id === 3) { console.log("\n[phase 2] answer to 'what number?' => " + answer.trim() + "   (42 = memory survived the restart)"); done(); }
  });
})();
