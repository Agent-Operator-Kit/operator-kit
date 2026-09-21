import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { transform } from 'esbuild';

test('serves real Operator state and a valid embedded UI over stdio', { timeout: 15000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'operator-console-'));
  const feature = join(root, 'operator', 'features', 'FS-0001-sample');
  await mkdir(feature, { recursive: true });
  await writeFile(join(root, 'operator.config.env'), `PROJECT_NAME="fixture"\nPROJECT_ROOT="${root}"\nOPERATOR_DIR="${join(root, 'operator')}"\nOPERATOR_KIT_VERSION="5.2"\nTMUX_SESSION="missing-session"\nOPERATOR_LANES='\nreview|Codex Desktop|fixture-review|feature/review|codex exec\n'\n`);
  await writeFile(join(feature, 'status.json'), JSON.stringify({ id: 'FS-0001', slug: 'sample', title: 'Sample feature', status: 'active', branch: 'feature/sample', updatedAt: '2026-09-11T10:00:00Z', boundChats: [], roleInstances: [] }));
  await writeFile(join(feature, 'graph.json'), JSON.stringify({ revision: 2, nodes: [
    { id: 'done', title: 'Completed task', state: 'completed', dependsOn: [], lane: 'review', approval: 'not-required' },
    { id: 'next', title: 'Next task', state: 'pending', dependsOn: ['done'], lane: 'review', approval: 'pending' }
  ] }));

  const client = new Client({ name: 'operator-console-test', version: '1' });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: ['dist/server.mjs'], env: { ...process.env, OPERATOR_PROJECT_ROOT: root } }));
  t.after(() => client.close());

  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map(tool => tool.name).sort(), ['operator_console', 'operator_console_refresh']);
  assert.equal(tools.tools[0]._meta.ui.resourceUri, 'ui://operator/console.html');

  const result = await client.callTool({ name: 'operator_console', arguments: { projectRoot: root } });
  assert.equal(result.isError, undefined);
  assert.equal(result.structuredContent.project.name, 'fixture');
  assert.equal(result.structuredContent.summary.runnableTasks, 1);
  assert.equal(result.structuredContent.summary.pendingApprovals, 1);
  assert.equal(result.structuredContent.features[0].graph.nodes.length, 2);
  assert.equal(result.structuredContent.capabilities.mode, 'read-only');

  const resource = await client.readResource({ uri: 'ui://operator/console.html' });
  assert.equal(resource.contents[0].mimeType, 'text/html;profile=mcp-app');
  assert.match(resource.contents[0].text, /Operator Console/);
  const html = resource.contents[0].text;
  const script = html.slice(html.indexOf('<script type="module">') + '<script type="module">'.length, html.lastIndexOf('</script>'));
  await transform(script, { loader: 'js' });
});

test('returns setup guidance rather than failing outside an Operator project', { timeout: 15000 }, async t => {
  const empty = await mkdtemp(join(tmpdir(), 'operator-console-empty-'));
  const client = new Client({ name: 'operator-console-empty-test', version: '1' });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [resolve('dist/server.mjs')], cwd: empty, env: { ...process.env, OPERATOR_PROJECT_ROOT: '' } }));
  t.after(() => client.close());
  const result = await client.callTool({ name: 'operator_console', arguments: { projectRoot: empty } });
  assert.equal(result.structuredContent.initialized, false);
  assert.match(result.content[0].text, /operator\.config\.env/);
});
