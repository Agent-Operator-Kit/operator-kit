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
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [resolve('dist/server.mjs')], env: { ...process.env, OPERATOR_PROJECT_ROOT: root } }));
  t.after(() => client.close());
  return client;
}
const call = (client, root, extra = {}) => client.callTool({ name: 'operator_console_refresh', arguments: { projectRoot: root, ...extra } });

test('publishes canonical readiness and refresh without a rendering resource', async t => {
  const f = await fixture(t); const client = await connect(t, f.root);
  const tools = (await client.listTools()).tools;
  assert.equal(tools.find(t => t.name === 'operator_console')._meta.ui.resourceUri, 'ui://operator/console-v2.html');
  assert.equal(tools.find(t => t.name === 'operator_console_refresh')._meta.ui.resourceUri, undefined);
  const state = (await call(client, f.root)).structuredContent;
  assert.equal(state.summary.eligibleTasks, 1);
  assert.equal(state.summary.recordedActiveTasks, 1);
  assert.equal(state.summary.attention, 1);
  assert.deepEqual(state.features[0].tasks.find(t => t.id === 'conflicting').reasons, ['conflict:active-work']);
  assert.equal(state.features[0].tasks.find(t => t.id === 'approval').eligible, false);
  assert.equal(state.lanes[0].activity, 'unknown');
  assert.equal('running' in state.lanes[0], false);
  const resource = await client.readResource({ uri: 'ui://operator/console-v2.html' });
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
