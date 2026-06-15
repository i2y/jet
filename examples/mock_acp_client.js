// Mock ACP CLIENT: drives a Jet ACP agent server, streams output inline, and
// does two turns to prove conversation memory.
//   node examples/mock_acp_client.js ./jet acp-serve acp_demo::Sage::reply examples/acp_demo.jet
const { spawn } = require('child_process');
const a = process.argv.slice(2);
const child = spawn(a[0], a.slice(1), { stdio: ['pipe', 'pipe', 'inherit'] });
const send = (o) => child.stdin.write(JSON.stringify(o) + '\n');
const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
function renderUpdate(u) {
  if (process.env.COMPACT) return renderCompact(u);   // tight lines for a GIF
  switch (u.sessionUpdate) {
    case 'agent_message_chunk': process.stdout.write(u.content.text); break;
    case 'agent_thought_chunk': process.stdout.write('\n  (thinking) ' + u.content.text); break;
    case 'plan': console.log('\n  [plan] ' + u.entries.map((e) => e.content).join(' -> ')); break;
    case 'tool_call': console.log('\n  [tool_call] ' + u.title + ' (kind=' + u.kind + ', ' + u.status + ')'); break;
    case 'tool_call_update': console.log('  [tool_update] ' + u.toolCallId + ' -> ' + u.status
      + (u.content ? ': ' + u.content[0].content.text : '')); break;
    default: console.log('\n  [' + u.sessionUpdate + ']');
  }
}
function renderCompact(u) {
  switch (u.sessionUpdate) {
    case 'plan': console.log('  plan: ' + u.entries.map((e) => e.content).join(' -> ')); break;
    case 'tool_call': console.log('  .. ' + pad(u.toolCallId, 8) + ' running'); break;
    case 'tool_call_update':
      console.log(u.status === 'failed'
        ? '  XX ' + pad(u.toolCallId, 8) + ' crashed -- isolated; the fleet was unaffected'
        : '  ok ' + pad(u.toolCallId, 8) + ' done'); break;
    case 'agent_thought_chunk': console.log('  ~  ' + u.content.text.trim()); break;
    case 'agent_message_chunk': {
      const t = u.content.text.trim().replace(/\s+/g, ' ');
      console.log('\n  => ' + (t.length > 220 ? t.slice(0, 220) + ' ...' : t)); break;
    }
    default: break;
  }
}
// Prompts: override with PROMPTS env (JSON array); default proves memory.
const PROMPTS = process.env.PROMPTS ? JSON.parse(process.env.PROMPTS)
  : ["Remember the number 42. Just say OK.", "What number did I ask you to remember?"];
const fs = require('fs');
function handleAgentRequest(m) {            // the agent calling back to us (the client)
  switch (m.method) {
    case 'fs/read_text_file': {
      let content = '';
      try { content = fs.readFileSync(m.params.path, 'utf8'); } catch (e) {}
      console.log('\n  <- [fs/read_text_file] ' + m.params.path + ' (' + content.length + ' bytes)');
      send({ jsonrpc: '2.0', id: m.id, result: { content } }); break;
    }
    case 'fs/write_text_file':
      try { fs.writeFileSync(m.params.path, m.params.content); } catch (e) {}
      console.log('\n  <- [fs/write_text_file] ' + m.params.path);
      send({ jsonrpc: '2.0', id: m.id, result: {} }); break;
    case 'session/request_permission':
      console.log('\n  <- [permission] auto-allow');
      send({ jsonrpc: '2.0', id: m.id, result: { outcome: { outcome: 'selected', optionId: 'allow' } } }); break;
    default:
      send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'unhandled: ' + m.method } });
  }
}
let buf = '', sid = null, pi = 0;
function nextPrompt() {
  if (pi >= PROMPTS.length) { console.log('\n--- done ---'); setTimeout(() => process.exit(0), 200); return; }
  const text = PROMPTS[pi]; const id = 3 + pi; pi++;
  console.log('\n[turn ' + pi + '] user: ' + text);
  const blocks = [];                       // ATTACH=<path> mimics an ACP @-mention (resource_link)
  if (process.env.ATTACH) blocks.push({ type:"resource_link", name: require('path').basename(process.env.ATTACH), uri: "file://" + process.env.ATTACH });
  blocks.push({ type:"text", text });
  send({ jsonrpc:"2.0", id, method:"session/prompt", params:{ sessionId:sid, prompt: blocks } });
}
child.stdout.on('data', (d) => {
  buf += d; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.method) {                          // a notification/request FROM the agent
      if (m.method === 'session/update') renderUpdate(m.params.update);
      else handleAgentRequest(m);            // fs/* , permission -> reply by id
    } else if (m.id === 1) send({ jsonrpc:"2.0", id:2, method:"session/new", params:{ cwd:".", mcpServers:[] } });
    else if (m.id === 2) { sid = m.result.sessionId; nextPrompt(); }
    else if (m.id >= 3) { nextPrompt(); }    // a reply to one of OUR requests -> next prompt
  }
});
setTimeout(() => send({ jsonrpc:"2.0", id:1, method:"initialize", params:{ protocolVersion:1, clientCapabilities:{} } }), 150);
