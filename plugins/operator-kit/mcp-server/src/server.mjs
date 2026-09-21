import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { existsSync, readFileSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { z } from 'zod';

const VERSION = '0.6.0';
const RESOURCE_URI = 'ui://operator/console.html';
const TERMINAL_STATUSES = new Set(['closed', 'integrated', 'shipped', 'parked', 'archived']);
let activeRoot = null;

function readJson(path, fallback = null) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return fallback; }
}

function ascend(start) {
  let cursor = resolve(start);
  while (true) {
    if (existsSync(join(cursor, 'operator.config.env'))) return cursor;
    const parent = dirname(cursor);
    if (parent === cursor) return null;
    cursor = parent;
  }
}

function candidateRoots(explicit) {
  const values = [explicit, activeRoot, process.env.OPERATOR_PROJECT_ROOT, process.cwd()];
  const expanded = [];
  for (const value of values.filter(Boolean)) {
    expanded.push(value);
    try {
      for (const name of readdirSync(value)) {
        const child = join(value, name);
        if (statSync(child).isDirectory()) expanded.push(child);
      }
    } catch {}
  }
  return [...new Set(expanded.map(value => resolve(value)))];
}

function findRoot(explicit) {
  if (explicit && !isAbsolute(explicit)) throw new Error('projectRoot must be an absolute path.');
  for (const candidate of candidateRoots(explicit)) {
    const found = ascend(candidate);
    if (found) return realpathSync(found);
  }
  return null;
}

function parseConfig(path) {
  const raw = readFileSync(path, 'utf8');
  const value = key => raw.match(new RegExp(`^${key}=["']?([^"'\\n]*)`, 'm'))?.[1]?.trim() || '';
  const laneBlock = raw.match(/^OPERATOR_LANES='\n([\s\S]*?)\n'/m)?.[1] || '';
  const lanes = laneBlock.split('\n').map(line => line.trim()).filter(Boolean).map(line => {
    const [id, owner, worktree, branch, command] = line.split('|');
    return { id, owner, worktree, branch, command, provider: command?.trim().split(/\s+/)[0] || 'unknown' };
  });
  return {
    projectName: value('PROJECT_NAME'), projectRoot: value('PROJECT_ROOT'), codeDir: value('CODE_DIR'),
    operatorDir: value('OPERATOR_DIR'), kitVersion: value('OPERATOR_KIT_VERSION'), tmuxSession: value('TMUX_SESSION'), lanes
  };
}

function findScripts(root) {
  const candidates = [join(root, 'scripts')];
  try {
    for (const name of readdirSync(root)) candidates.push(join(root, name, 'scripts'));
  } catch {}
  return candidates.find(path => existsSync(join(path, 'operator-feature.sh'))) || null;
}

function tmuxWindows(session) {
  if (!session) return new Set();
  const result = spawnSync('tmux', ['list-windows', '-t', session, '-F', '#{window_name}'], { encoding: 'utf8', timeout: 2500 });
  return result.status === 0 ? new Set(result.stdout.trim().split('\n').filter(Boolean)) : new Set();
}

function readFeatures(operatorDir) {
  const featuresDir = join(operatorDir, 'features');
  if (!existsSync(featuresDir)) return [];
  return readdirSync(featuresDir, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && entry.name.startsWith('FS-'))
    .map(entry => {
      const folder = join(featuresDir, entry.name);
      const status = readJson(join(folder, 'status.json'), {});
      const graph = readJson(join(folder, 'graph.json'), { nodes: [], revision: 0 });
      const nodes = Array.isArray(graph.nodes) ? graph.nodes : [];
      const counts = nodes.reduce((acc, node) => { acc[node.state || 'unknown'] = (acc[node.state || 'unknown'] || 0) + 1; return acc; }, {});
      const runnable = nodes.filter(node => ['pending', 'ready'].includes(node.state) && (node.dependsOn || []).every(id => nodes.find(other => other.id === id)?.state === 'completed'));
      return {
        id: status.id || entry.name.split('-').slice(0, 2).join('-'), slug: status.slug || entry.name,
        title: status.title || entry.name, status: status.status || 'unknown', branch: status.branch || '',
        worktree: status.worktree || '', updatedAt: status.updatedAt || status.lastActivity || graph.updatedAt || '',
        boundChats: status.boundChats || [], roles: status.roleInstances || [], claims: status.claims || {},
        merge: status.merge || {}, graph: { revision: graph.revision || 0, nodes, counts, runnable: runnable.map(node => node.id) }
      };
    })
    .filter(feature => !TERMINAL_STATUSES.has(feature.status))
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
}

function conflictSummary(root, scripts) {
  if (!scripts || !existsSync(join(scripts, 'operator-conflicts.sh'))) return '';
  const result = spawnSync('bash', [join(scripts, 'operator-conflicts.sh'), 'summary'], { cwd: root, encoding: 'utf8', timeout: 5000 });
  return (result.stdout || result.stderr || '').trim();
}

function snapshot(projectRoot) {
  const root = findRoot(projectRoot);
  if (!root) {
    return { schemaVersion: 'operator.console/v1', initialized: false, searchedFrom: projectRoot || process.cwd(), message: 'No operator.config.env was found. Open the console from an initialized Operator project or pass its absolute project root.', generatedAt: new Date().toISOString() };
  }
  activeRoot = root;
  const config = parseConfig(join(root, 'operator.config.env'));
  const operatorDir = config.operatorDir && isAbsolute(config.operatorDir) ? config.operatorDir : join(root, config.operatorDir || 'operator');
  const windows = tmuxWindows(config.tmuxSession);
  const lanes = config.lanes.map(lane => ({ ...lane, running: windows.has(lane.id) }));
  const features = readFeatures(operatorDir);
  const scripts = findScripts(root);
  return {
    schemaVersion: 'operator.console/v1', initialized: true, generatedAt: new Date().toISOString(),
    project: { name: config.projectName || basename(root), root, kitVersion: config.kitVersion || 'unknown', operatorDir },
    summary: {
      activeFeatures: features.length, runningLanes: lanes.filter(lane => lane.running).length,
      runnableTasks: features.reduce((sum, feature) => sum + feature.graph.runnable.length, 0),
      pendingApprovals: features.reduce((sum, feature) => sum + feature.graph.nodes.filter(node => node.approval === 'pending').length, 0)
    },
    lanes, features, conflicts: conflictSummary(root, scripts), capabilities: { mode: 'read-only', embeddedActions: ['refresh', 'ask-plan', 'ask-conflicts', 'ask-status'] }
  };
}

function textSummary(state) {
  if (!state.initialized) return state.message;
  return `${state.project.name}: ${state.summary.activeFeatures} active features, ${state.summary.runnableTasks} runnable tasks, ${state.summary.runningLanes} running lanes. The embedded Operator Console is attached.`;
}

const rootSchema = { projectRoot: z.string().optional().describe('Absolute root of the initialized Operator project. Pass the current workspace root when known.') };
const server = new McpServer({ name: 'operator-console', version: VERSION });

for (const [name, title, description] of [
  ['operator_console', 'Open Operator Console', 'Open the embedded, read-only Operator project console. Pass the current workspace root when known.'],
  ['operator_console_refresh', 'Refresh Operator Console', 'Refresh the embedded Operator project console without changing project state.']
]) {
  registerAppTool(server, name, {
    title, description, inputSchema: rootSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    _meta: { ui: { resourceUri: RESOURCE_URI, visibility: ['app', 'model'] }, 'openai/outputTemplate': RESOURCE_URI }
  }, async ({ projectRoot }) => {
    try {
      const state = snapshot(projectRoot);
      return { content: [{ type: 'text', text: textSummary(state) }], structuredContent: state };
    } catch (error) {
      return { isError: true, content: [{ type: 'text', text: `Operator Console: ${error.message}` }] };
    }
  });
}

registerAppResource(server, 'Operator Console', RESOURCE_URI, { mimeType: RESOURCE_MIME_TYPE }, async () => ({
  contents: [{
    uri: RESOURCE_URI, mimeType: RESOURCE_MIME_TYPE,
    text: await readFile(new URL('../dist/console.html', import.meta.url), 'utf8'),
    _meta: { ui: { prefersBorder: true, csp: { connectDomains: [], resourceDomains: [] } } }
  }]
}));

await server.connect(new StdioServerTransport());
