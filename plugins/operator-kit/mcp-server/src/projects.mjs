import { existsSync, readFileSync, readdirSync, mkdirSync, writeFileSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { projectInfo } from './state.mjs';

export const defaults = { language: 'auto', appearance: 'auto', allProjects: false };
export const registryPath = () => process.env.OPERATOR_CONSOLE_REGISTRY || join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'operator', 'console', 'projects.json');
function registry() {
  const path = registryPath();
  if (!existsSync(path)) return { version: 1, roots: [], preferences: defaults };
  const value = JSON.parse(readFileSync(path, 'utf8'));
  if (value.version !== 1 || !Array.isArray(value.roots) || !value.roots.every(r => typeof r === 'string')) throw new Error('Invalid Operator console registry. Repair projects.json before adding projects.');
  return value;
}
function update(change) {
  const path = registryPath(), lock = `${path}.lock`, temporary = `${path}.${randomUUID()}.tmp`;
  mkdirSync(dirname(path), { recursive: true });
  try { mkdirSync(lock); } catch { throw new Error('Project settings are being saved by another console. Retry shortly.'); }
  try {
    const next = change(registry());
    writeFileSync(temporary, JSON.stringify(next, null, 2) + '\n', { mode: 0o600 });
    renameSync(temporary, path);
    return next;
  } finally { rmSync(temporary, { force: true }); rmSync(lock, { recursive: true, force: true }); }
}
export function registerProject(root) {
  const project = projectInfo(root);
  update(data => {
    // Worktrees pointing at the same Operator directory represent one cockpit.
    const duplicate = data.roots.some(r => { try { return projectInfo(r).operatorDir === project.operatorDir; } catch { return r === project.root; } });
    return { ...data, roots: duplicate ? data.roots : [...data.roots, project.root] };
  });
  return project;
}
export function savePreferences(preferences) {
  if (!['auto', 'en', 'pl'].includes(preferences.language) || !['auto', 'light', 'dark'].includes(preferences.appearance) || typeof preferences.allProjects !== 'boolean') throw new Error('Invalid console preferences.');
  update(data => ({ ...data, preferences }));
  return preferences;
}
export function listProjects(currentRoot) {
  const data = registry(), seen = new Set();
  const projects = [...new Set([currentRoot, ...data.roots].filter(Boolean))].flatMap(root => {
    try {
      const project = projectInfo(root);
      if (seen.has(project.operatorDir)) return [];
      seen.add(project.operatorDir);
      const folder = join(project.operatorDir, 'features');
      let features = 0, attention = 0, active = 0, lastActivity = '';
      for (const entry of existsSync(folder) ? readdirSync(folder, { withFileTypes: true }) : []) {
        if (!entry.isDirectory() || !entry.name.startsWith('FS-')) continue;
        const status = JSON.parse(readFileSync(join(folder, entry.name, 'status.json'), 'utf8'));
        if (typeof status.id !== 'string' || typeof status.status !== 'string') throw new Error('Incomplete feature status');
        features++;
        if (['blocked', 'in-review', 'human-feedback'].includes(status.status)) attention++;
        lastActivity = [lastActivity, status.updatedAt || status.lastActivity || ''].sort().at(-1);
        const graphPath = join(folder, entry.name, 'graph.json');
        if (existsSync(graphPath)) {
          const graph = JSON.parse(readFileSync(graphPath, 'utf8'));
          if (!Array.isArray(graph.nodes) || graph.featureId !== status.id) throw new Error('Invalid feature graph');
          active += graph.nodes.filter(n => n.state === 'active').length;
          attention += graph.nodes.filter(n => ['blocked', 'failed'].includes(n.state) || n.approval === 'pending').length;
          lastActivity = [lastActivity, graph.updatedAt || ''].sort().at(-1);
        }
      }
      return [{ ...project, available: true, summary: { features, attention, active }, lastActivity }];
    } catch (error) { return [{ root, name: root.split('/').at(-1), available: false, error: error.message }]; }
  });
  return { projects, preferences: { ...defaults, ...data.preferences }, generatedAt: new Date().toISOString() };
}
