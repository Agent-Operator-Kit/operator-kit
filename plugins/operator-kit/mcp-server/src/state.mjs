import { existsSync, readFileSync, readdirSync, realpathSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
function json(path, optional = false) {
  if (optional && !existsSync(path)) return null;
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch { throw new Error(`Cannot read valid Operator record: ${path}`); }
}
function literal(raw, key) {
  const line = raw.split('\n').find(line => line.startsWith(`${key}=`));
  if (!line) return '';
  const value = line.slice(key.length + 1).trim();
  const match = value.match(/^(?:"([^"\n]*)"|'([^'\n]*)'|([^\s#]+))\s*(?:#.*)?$/);
  if (!match) throw new Error(`Unsupported config value: ${key}. Use a literal path or value.`);
  const result = match[1] ?? match[2] ?? match[3];
  if (/[$`]/.test(result)) throw new Error(`Config expansion is not supported for ${key}.`);
  return result;
}
function config(root) {
  const raw = readFileSync(join(root, 'operator.config.env'), 'utf8');
  const block = raw.match(/^OPERATOR_LANES='\r?\n([\s\S]*?)\r?\n'/m)?.[1] || '';
  return {
    name: literal(raw, 'PROJECT_NAME') || basename(root),
    id: literal(raw, 'OPERATOR_PROJECT_ID'),
    operatorDir: resolve(root, literal(raw, 'OPERATOR_DIR') || 'operator'),
    kitVersion: literal(raw, 'OPERATOR_KIT_VERSION') || 'unknown',
    session: literal(raw, 'TMUX_SESSION'),
    lanes: block.split('\n').map(line => line.trim()).filter(Boolean).map(line => {
      const [id, owner, worktree, branch] = line.split('|');
      return { id, owner, worktree, branch };
    })
  };
}
function frontier(root, operatorDir, capacity) {
  const script = join(root, 'scripts', 'operator_local_graph.py');
  if (!existsSync(script)) return { available: false, reason: 'Canonical graph runtime is not installed.', runnable: [], excluded: [] };
  const python = process.env.OPERATOR_PYTHON_PATH || (process.platform === 'darwin' && existsSync('/Library/Developer/CommandLineTools/usr/bin/python3') ? '/Library/Developer/CommandLineTools/usr/bin/python3' : 'python3');
  const result = spawnSync(python, ['-E', '-s', script, '--operator-dir', operatorDir, 'frontier', '--capacity', String(capacity), '--json'], { encoding: 'utf8', timeout: 5000, maxBuffer: 2 * 1024 * 1024 });
  if (result.status !== 0) return { available: false, reason: (result.stderr || result.error?.message || 'Canonical frontier failed.').trim().slice(0, 500), runnable: [], excluded: [] };
  try {
    const value = JSON.parse(result.stdout);
    if (value.schemaVersion !== 'operator.local-frontier/v1') throw new Error();
    return { available: true, ...value };
  } catch { return { available: false, reason: 'Invalid canonical frontier response.', runnable: [], excluded: [] }; }
}
function windows(session) {
  if (!session) return { available: false, names: [] };
  const result = spawnSync('tmux', ['list-windows', '-t', session, '-F', '#{window_name}'], { encoding: 'utf8', timeout: 2000 });
  return { available: result.status === 0, names: result.status === 0 ? result.stdout.trim().split('\n') : [] };
}
function text(path) { return existsSync(path) ? readFileSync(path, 'utf8').slice(0, 6000) : ''; }
function events(path, featureId) {
  if (!existsSync(path)) return [];
  const lines = readFileSync(path, 'utf8').split('\n').filter(Boolean).slice(-8);
  return lines.flatMap(line => {
    try {
      const event = JSON.parse(line);
      return [{ featureId, occurredAt: event.occurredAt, action: event.action, taskId: event.details?.nodeId || '', state: event.details?.to || '', source: 'Operator graph event' }];
    } catch { return []; }
  });
}

function viewPath(project) { return join(project.operatorDir, 'console', 'views', `${hash(homedir()).slice(0, 16)}.json`); }
export function saveView(project, view) {
  const path = viewPath(project);
  mkdirSync(join(project.operatorDir, 'console', 'views'), { recursive: true });
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, JSON.stringify(view), { mode: 0o600 });
  renameSync(temporary, path);
}

export function snapshot(projectRoot, capacity = 4) {
  if (!projectRoot || !isAbsolute(projectRoot)) throw new Error('Pass the absolute initialized projectRoot. This console never falls back to another project.');
  if (!existsSync(join(projectRoot, 'operator.config.env'))) throw new Error('No operator.config.env at the requested projectRoot. Select an initialized Operator project.');
  const root = realpathSync(projectRoot);
  const cfg = config(root);
  const operatorDir = realpathSync(cfg.operatorDir);
  const project = { id: cfg.id || `local-${hash(root).slice(0, 20)}`, root, operatorDir, name: cfg.name, kitVersion: cfg.kitVersion, identityScope: cfg.id ? 'configured' : 'local-path' };
  const readiness = frontier(root, operatorDir, capacity);
  const windowState = windows(cfg.session);
  const featuresDir = join(operatorDir, 'features');
  const features = !existsSync(featuresDir) ? [] : readdirSync(featuresDir, { withFileTypes: true }).filter(e => e.isDirectory() && e.name.startsWith('FS-')).sort((a, b) => a.name.localeCompare(b.name)).map(entry => {
    const folder = join(featuresDir, entry.name);
    const status = json(join(folder, 'status.json'));
    if (typeof status.id !== 'string' || typeof status.status !== 'string') throw new Error(`Incomplete feature status: ${entry.name}`);
    const graph = json(join(folder, 'graph.json'), true);
    if (graph && (!Array.isArray(graph.nodes) || graph.featureId !== status.id)) throw new Error(`Invalid graph for ${status.id}`);
    const tasks = (graph?.nodes || []).map(node => {
      const eligible = readiness.available && readiness.runnable.some(item => item.featureId === status.id && item.node.id === node.id);
      const reasons = readiness.excluded.find(item => item.featureId === status.id && item.node.id === node.id)?.reasons || [];
      return { id: node.id, title: node.title || node.id, state: node.state, lane: node.lane, approval: node.approval, dependsOn: node.dependsOn || [], eligible, reasons, updatedAt: graph.updatedAt, source: 'Operator dependency graph' };
    });
    const recordNames = ['feature.md', 'decisions.md', 'memory.md'];
    return { id: status.id, title: status.title || status.id, status: status.status, branch: status.branch || '', worktree: status.worktree || '', updatedAt: status.updatedAt || status.lastActivity || '', boundChats: (status.boundChats || []).filter(c => c.tool === 'codex' && typeof c.chat === 'string').map(c => ({ id: c.chat, boundAt: c.boundAt })), tasks, graphRevision: graph?.revision ?? null, recentChanges: events(join(folder, 'graph-events.jsonl'), status.id), brief: text(join(folder, 'feature.md')), records: recordNames.filter(name => existsSync(join(folder, name))).map(name => ({ name, path: join(folder, name), excerpt: text(join(folder, name)) })) };
  });
  const attention = features.flatMap(feature => [
    ...(['blocked', 'in-review', 'human-feedback'].includes(feature.status) ? [{ featureId: feature.id, title: feature.title, reason: `Feature: ${feature.status}`, source: 'Recorded feature status' }] : []),
    ...feature.tasks.filter(task => ['blocked', 'failed'].includes(task.state) || task.approval === 'pending').map(task => ({ featureId: feature.id, taskId: task.id, title: task.title, reason: task.approval === 'pending' ? 'Approval pending' : task.state, source: task.source }))
  ]);
  const data = { schemaVersion: 'operator.console/v2', project, features, attention, readiness, lanes: cfg.lanes.map(lane => ({ ...lane, windowPresent: windowState.available ? windowState.names.includes(lane.id) : null, activity: 'unknown' })), summary: { features: features.length, recordedActiveTasks: features.reduce((n, f) => n + f.tasks.filter(t => t.state === 'active').length, 0), attention: attention.length, eligibleTasks: readiness.available ? readiness.runnable.length : null }, capabilities: { mode: 'read-only', pollIntervalMs: 4000, collaboration: 'local-records', knowledge: 'local-documents' } };
  let savedView = null;
  try { savedView = json(viewPath(project), true); } catch { /* A damaged UI preference must not hide business records. */ }
  return { ...data, savedView, revision: hash(data), generatedAt: new Date().toISOString() };
}
