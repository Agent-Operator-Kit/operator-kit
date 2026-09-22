import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

async function fixture(t, name = 'fixture') {
  const root = await mkdtemp(join(tmpdir(), 'operator-console-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const folder = join(root, 'operator/features/FS-0001-sample');
  await mkdir(folder, { recursive: true });
  await mkdir(join(root, 'scripts'));
  await copyFile(resolve('../../../scripts/operator_local_graph.py'), join(root, 'scripts/operator_local_graph.py'));
  await writeFile(join(root, 'operator.config.env'), `PROJECT_NAME="${name}"\nOPERATOR_DIR="${root}/operator"\nOPERATOR_KIT_VERSION="5.2"\nTMUX_SESSION="missing-poc-session"\nOPERATOR_LANES='\nworker|Codex Desktop|fixture|feature/test|codex\n'\n`);
  await writeFile(join(folder, 'status.json'), JSON.stringify({ id: 'FS-0001', title: 'Sample feature', status: 'active' }));
  const task = (id, state, lane, approval = 'not-required', files = []) => ({ id, title: id, kind: 'task', state, priority: 10, lane, approval, dependsOn: [], claims: { files, contracts: [], resources: [], surfaces: [] }, taskFile: null });
  const graph = { schemaVersion: 'operator.local-dependency-graph/v1', featureId: 'FS-0001', revision: 1, updatedAt: '2026-09-21T10:00:00Z', nodes: [task('working', 'active', 'worker', 'not-required', ['shared.txt']), task('conflicting', 'pending', 'review', 'not-required', ['shared.txt']), task('approval', 'pending', 'review', 'pending'), task('eligible', 'pending', 'free')] };
  const graphFile = join(folder, 'graph.json');
  await writeFile(graphFile, JSON.stringify(graph));
  return { root, folder, graphFile, graph };
}
async function connect(t, root) {
  const client = new Client({ name: 'operator-poc-test', version: '1' });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [resolve('dist/server.mjs')], env: { ...process.env, OPERATOR_PROJECT_ROOT: root, OPERATOR_CONSOLE_REGISTRY: join(root, "registry.json") } }));
  t.after(() => client.close());
  return client;
}
const call = (client, root, extra = {}) => client.callTool({ name: 'operator_console_refresh', arguments: { projectRoot: root, ...extra } });

test('SSH browser port admits matching requests and rejects other hosts, origins and missing tokens', async t => {
  const { createServer } = await import('node:net');
  const { request } = await import('node:http');
  const { spawn } = await import('node:child_process');
  const f = await fixture(t);
  const reservation = createServer();
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const browserPort = port === 43133 ? 43134 : 43133;
  const child = spawn(process.execPath, [resolve('dist/cli.mjs'), 'serve', f.root, String(port), String(browserPort)], { env: { ...process.env, OPERATOR_CONSOLE_REGISTRY: join(f.root, 'registry.json') }, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => { if (child.exitCode !== null) return; await new Promise(resolve => { child.once('exit', resolve); child.kill('SIGTERM'); }); });
  await new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error(`Preview startup timeout: ${output}`)), 15000);
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('exit', code => { clearTimeout(timeout); reject(new Error(`Preview exited: ${code}: ${output}`)); });
    child.stdout.on('data', chunk => { output += chunk; if (output.includes('Operator v6-alpha:')) { clearTimeout(timeout); resolve(); } });
    child.stderr.on('data', chunk => { output += chunk; });
  });
  const http = (path, host, headers = {}, body) => new Promise((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port, path, method: body === undefined ? 'GET' : 'POST', headers: { Host: host, ...headers } }, response => {
      let text = ''; response.on('data', chunk => { text += chunk; }); response.on('end', () => resolve({ status: response.statusCode, text }));
    });
    req.on('error', reject); req.end(body);
  });
  const host = `127.0.0.1:${browserPort}`;
  const page = await http('/', host);
  assert.equal(page.status, 200);
  assert.equal((await http('/', `127.0.0.1:${port}`)).status, 200);
  assert.equal((await http('/', 'untrusted.example')).status, 403);
  const token = JSON.parse(page.text.match(/<script id="config" type="application\/json">([^<]+)<\/script>/)[1]).token;
  assert.equal((await http('/initial', host)).status, 403);
  const headers = { 'X-Operator-Token': token, Origin: `http://${host}`, 'Content-Type': 'application/json' };
  const body = JSON.stringify({ name: 'operator_console_refresh', arguments: { projectRoot: f.root } });
  const result = await http('/rpc', host, headers, body);
  assert.equal(result.status, 200);
  assert.equal(JSON.parse(result.text).structuredContent.project.name, 'fixture');
  assert.equal((await http('/rpc', host, { ...headers, Origin: 'https://untrusted.example' }, body)).status, 403);
  assert.equal((await http('/rpc', host, { ...headers, Origin: `http://127.0.0.1:${port}` }, body)).status, 403);
});

test('publishes canonical readiness and refresh without a rendering resource', async t => {
  const f = await fixture(t); const client = await connect(t, f.root);
  const tools = (await client.listTools()).tools;
  assert.equal(tools.find(t => t.name === 'operator_console')._meta.ui.resourceUri, 'ui://operator/console-v6-alpha.html');
  assert.equal(tools.find(t => t.name === 'operator_console_refresh')._meta.ui.resourceUri, undefined);
  const state = (await call(client, f.root)).structuredContent;
  assert.equal(state.summary.eligibleTasks, 1);
  assert.equal(state.summary.recordedActiveTasks, 1);
  assert.equal(state.summary.attention, 1);
  assert.deepEqual(state.features[0].tasks.find(t => t.id === 'conflicting').reasons, ['conflict:active-work']);
  assert.equal(state.features[0].tasks.find(t => t.id === 'approval').eligible, false);
  assert.equal(state.lanes[0].activity, 'unknown');
  assert.equal('running' in state.lanes[0], false);
  const resource = await client.readResource({ uri: 'ui://operator/console-v6-alpha.html' });
  assert.equal(resource.contents[0].mimeType, 'text/html;profile=mcp-app');
});

test('acknowledges unchanged reads and discovers changes from another writer', async t => {
  const f = await fixture(t); const client = await connect(t, f.root);
  const state = (await call(client, f.root)).structuredContent;
  const unchanged = (await call(client, f.root, { projectId: state.project.id, sinceRevision: state.revision })).structuredContent;
  assert.equal(unchanged.unchanged, true);
  assert.equal(unchanged.features, undefined);
  f.graph.nodes[0].state = 'completed'; f.graph.revision++;
  await writeFile(f.graphFile, JSON.stringify(f.graph));
  const changed = (await call(client, f.root, { sinceRevision: state.revision })).structuredContent;
  assert.notEqual(changed.revision, state.revision);
  assert.equal(changed.features[0].tasks[0].state, 'completed');
  assert.equal(changed.summary.eligibleTasks, 2);
});

test('requires explicit binding and never falls back to an earlier or environment project', async t => {
  const a = await fixture(t, 'A'), b = await fixture(t, 'B'); const client = await connect(t, a.root);
  const stateA = (await call(client, a.root)).structuredContent;
  const stateB = (await call(client, b.root)).structuredContent;
  assert.notEqual(stateA.project.id, stateB.project.id);
  assert.equal(stateB.project.name, 'B');
  assert.equal((await call(client, b.root, { projectId: stateA.project.id })).isError, true);
  assert.equal((await call(client, join(a.root, 'missing'))).isError, true);
  assert.equal((await client.callTool({ name: 'operator_console_refresh', arguments: {} })).isError, true);
  assert.equal((await call(client, a.root)).structuredContent.project.name, 'A');
});

test('persists only view preferences, scoped to the project, without changing business revision', async t => {
  const a = await fixture(t, 'A'), b = await fixture(t, 'B'); const client = await connect(t, a.root);
  const before = (await call(client, a.root)).structuredContent;
  const view = { selectedId: 'FS-0001', selectedTask: 'working', tab: 'work', scrollY: 250 };
  const result = await client.callTool({ name: 'operator_console_save_view', arguments: { projectRoot: a.root, projectId: before.project.id, view } });
  assert.equal(result.structuredContent.saved, true);
  const after = (await call(client, a.root)).structuredContent;
  assert.deepEqual(after.savedView, view); assert.equal(before.revision, after.revision);
  assert.equal((await call(client, b.root)).structuredContent.savedView, null);
  const another = await connect(t, a.root);
  assert.deepEqual((await call(another, a.root)).structuredContent.savedView, view);
});

test('malformed records return errors; missing canonical runtime does not invent eligibility', async t => {
  const f = await fixture(t); const client = await connect(t, f.root);
  await rm(join(f.root, 'scripts/operator_local_graph.py'));
  const state = (await call(client, f.root)).structuredContent;
  assert.equal(state.readiness.available, false); assert.equal(state.summary.eligibleTasks, null);
  await writeFile(f.graphFile, '{broken');
  assert.equal((await call(client, f.root)).isError, true);
});

test('registry shares projects and preferences across server processes, deduplicates shared state, and isolates failures', async t => {
  const a = await fixture(t, 'A'), b = await fixture(t, 'B'); const client = await connect(t, a.root);
  const register = root => client.callTool({ name: 'operator_console_register_project', arguments: { projectRoot: root } });
  assert.equal((await register(a.root)).isError, undefined);
  assert.equal((await register(b.root)).isError, undefined);
  assert.equal((await register(b.root)).isError, undefined);
  const alias = join(a.root, 'worktree'); await mkdir(alias);
  await writeFile(join(alias, 'operator.config.env'), `PROJECT_NAME="same project"\nOPERATOR_DIR="${a.root}/operator"\n`);
  await register(alias);
  const list = async c => (await c.callTool({ name: 'operator_console_projects', arguments: { projectRoot: a.root } })).structuredContent;
  assert.equal((await list(client)).projects.length, 2);
  assert.equal((await list(client)).projects[0].summary.attention, 1);
  const prefs = { language: 'pl', appearance: 'dark', allProjects: true };
  await client.callTool({ name: 'operator_console_preferences', arguments: prefs });
  const another = await connect(t, a.root);
  assert.deepEqual((await list(another)).preferences, prefs);
  await writeFile(join(b.folder, 'status.json'), '{broken');
  const result = await list(another);
  assert.equal(result.projects[0].available, true);
  assert.equal(result.projects[1].available, false);
  assert.equal((await call(client, a.root)).structuredContent.project.name, 'A');
  assert.equal((await register(join(a.root, 'missing'))).isError, true);
});

test('registry and preference changes do not change project revisions; preferences reject invalid choices', async t => {
  const a = await fixture(t), client = await connect(t, a.root);
  const before = (await call(client, a.root)).structuredContent;
  await client.callTool({ name: 'operator_console_register_project', arguments: { projectRoot: a.root } });
  await client.callTool({ name: 'operator_console_preferences', arguments: { language: 'pl', appearance: 'light', allProjects: true } });
  assert.equal((await call(client, a.root)).structuredContent.revision, before.revision);
  assert.equal((await client.callTool({ name: 'operator_console_preferences', arguments: { language: 'bad', appearance: 'dark', allProjects: true } })).isError, true);
});

test('damaged registry fails explicitly without preventing a bound project read', async t => {
  const a = await fixture(t), client = await connect(t, a.root);
  await writeFile(join(a.root, 'registry.json'), '{broken');
  assert.equal((await client.callTool({ name: 'operator_console_projects', arguments: {} })).isError, true);
  assert.equal((await client.callTool({ name: 'operator_console_register_project', arguments: { projectRoot: a.root } })).isError, true);
  assert.equal((await call(client, a.root)).structuredContent.project.name, 'fixture');
});

test('standalone package starts from an unrelated working directory without node_modules', async t => {
  const { cp, chmod } = await import('node:fs/promises');
  const a = await fixture(t), packageRoot = join(a.root, 'relocated package');
  await mkdir(packageRoot); await cp(resolve('dist'), join(packageRoot, 'dist'), { recursive: true });
  await copyFile(resolve('launch'), join(packageRoot, 'launch')); await chmod(join(packageRoot, 'launch'), 0o755);
  const client = new Client({ name: 'relocation-test', version: '1' });
  await client.connect(new StdioClientTransport({ command: join(packageRoot, 'launch'), args: [], cwd: a.root, env: { ...process.env, CODEX_MCP_NODE_PATH: process.execPath, OPERATOR_CONSOLE_REGISTRY: join(a.root, 'registry.json') } }));
  t.after(() => client.close());
  assert.equal((await call(client, a.root)).structuredContent.project.name, 'fixture');
  const resource = await client.readResource({ uri: 'ui://operator/console-v6-alpha.html' });
  assert.match(resource.contents[0].text, /v6-alpha/);
  const { execFileSync } = await import('node:child_process');
  const config = execFileSync(process.execPath, [join(packageRoot, 'dist/cli.mjs'), 'config'], { encoding: 'utf8', cwd: a.root });
  assert.ok(config.includes(join(packageRoot, 'launch')));
});
