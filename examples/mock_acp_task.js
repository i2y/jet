// Mock ACP agent: streams a plan + a tool_call (with diff+terminal content and
// locations) + a message, to test `task` -> TurnResult population.
const rl = require('readline').createInterface({ input: process.stdin });
const send = (o) => process.stdout.write(JSON.stringify(o) + "\n");
rl.on('line', (line) => {
  if (!line.trim()) return;
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.method === 'initialize')
    send({ jsonrpc:"2.0", id:m.id, result:{ protocolVersion:1, agentCapabilities:{} } });
  else if (m.method === 'session/new')
    send({ jsonrpc:"2.0", id:m.id, result:{ sessionId:"mock-task-1" } });
  else if (m.method === 'session/prompt') {
    const sid = m.params.sessionId;
    const up = (u) => send({ jsonrpc:"2.0", method:"session/update", params:{ sessionId:sid, update:u } });
    up({ sessionUpdate:"plan", entries:[{content:"run tests",status:"pending"},{content:"fix",status:"pending"}] });
    up({ sessionUpdate:"tool_call", toolCallId:"t1", title:"Run tests", kind:"execute", status:"pending" });
    up({ sessionUpdate:"tool_call_update", toolCallId:"t1", title:"Run tests", kind:"execute", status:"completed",
         content:[ {type:"diff", path:"test/foo_test.exs", oldText:"assert 1==2", newText:"assert 1==1"},
                   {type:"terminal", terminalId:"term-1"} ],
         locations:[ {path:"test/foo_test.exs", line:10} ] });
    up({ sessionUpdate:"agent_message_chunk", content:{ type:"text", text:"Done: tests pass." } });
    send({ jsonrpc:"2.0", id:m.id, result:{ stopReason:"end_turn" } });
  }
});
