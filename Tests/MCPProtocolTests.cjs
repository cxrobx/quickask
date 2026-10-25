// Run: node Tests/MCPProtocolTests.cjs ../QuickAsk.app
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const executable = path.resolve(process.argv[2] || '../QuickAsk.app', 'Contents/MacOS/QuickAsk');
const requests = [
  { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } } },
  { jsonrpc: '2.0', method: 'notifications/initialized' },
  { jsonrpc: '2.0', id: 2, method: 'tools/list' },
  { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'inspect_ui', arguments: {} } },
  { jsonrpc: '2.0', id: 4, method: 'not/a/method' }
];
const child = spawnSync(executable, ['--mcp', '--target-pid', '0', '--owner-pid', '0', '--lease', '/private/tmp/quickask-nonexistent-test-lease'], {
  input: requests.map(JSON.stringify).join('\n') + '\n', encoding: 'utf8', timeout: 10000
});
if (child.error || child.status !== 0) throw child.error || new Error(child.stderr);
const responses = child.stdout.trim().split('\n').map(line => JSON.parse(line));
const get = id => responses.find(value => value.id === id);
if (responses.length !== 4) throw new Error('Notifications must not receive replies');
if (get(1).result.protocolVersion !== '2025-06-18' || !get(1).result.capabilities.tools) throw new Error('Initialize failed');
if (get(2).result.tools.length !== 20) throw new Error('Incomplete tool catalog');
if (!get(3).result.isError || !get(3).result.content[0].text.includes('stopped or expired')) throw new Error('Revoked control must be denied');
if (get(4).error.code !== -32601) throw new Error('Unknown methods must return a JSON-RPC error');
console.log('PASS: MCP initialization, discovery, notification handling, revocation, and JSON-RPC errors');
