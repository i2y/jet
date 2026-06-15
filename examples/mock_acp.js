// Minimal mock ACP agent (ndjson JSON-RPC over stdio) for examples/agent_acp.jet.
// Swap the runner command in agent_acp.jet for `claude-code-acp` to drive real
// Claude Code instead of this mock.
const rl = require('readline').createInterface({ input: process.stdin });
const send = (o) => process.stdout.write(JSON.stringify(o) + "\n");
rl.on('line', (line) => {
  if (!line.trim()) return;
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.method === 'initialize')
    send({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: 1, agentCapabilities: {} } });
  else if (m.method === 'session/new')
    send({ jsonrpc: "2.0", id: m.id, result: { sessionId: "mock-session-1" } });
  else if (m.method === 'session/prompt') {
    send({ jsonrpc: "2.0", method: "session/update", params: {
      sessionId: m.params.sessionId,
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello from the mock ACP agent." } } } });
    send({ jsonrpc: "2.0", id: m.id, result: { stopReason: "end_turn" } });
  }
});
