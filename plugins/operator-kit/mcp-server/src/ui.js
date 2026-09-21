import { App, applyDocumentTheme, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';
import { resolveLocale, translate } from './i18n.js';

const root = document.querySelector('#app'), notice = document.querySelector('#notice');
const bridge = new App({ name: 'Operator v6-alpha', version: '0.6.0-alpha.1' }, { availableDisplayModes: ['inline', 'fullscreen'] });
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
let state, selectedId, selectedTask, timer, busy = false, failures = 0, lastRead, connected = false, saveTimer;
let currentTab = 'work', error = '', toolRoot, restored = false, switching = false, restoringScroll = false;
let displayMode = 'inline', availableDisplayModes, changingDisplayMode = false;
let preferences = { language: 'auto', appearance: 'auto', allProjects: false }, preferencesLoaded = false;
let hostContext = {}, locale = 'en-US', projects = [], projectsError = '', projectsAt, projectsBusy = false, settingsWrite = Promise.resolve();
const views = new Map();
const t = message => translate(locale, message);
const h = message => escape(t(message));
const number = value => new Intl.NumberFormat(locale).format(value);
const stamp = value => value ? new Date(value).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit', ...(hostContext.timeZone ? { timeZone: hostContext.timeZone } : {}) }) : t('not yet');
const view = () => ({ selectedId: selectedId || null, selectedTask: selectedTask || null, tab: currentTab, scrollY: Math.min(1000000, Math.max(0, window.scrollY)) });
function say(message) { notice.textContent = message; notice.className = 'show'; clearTimeout(say.timer); say.timer = setTimeout(() => { notice.className = ''; }, 6000); }
async function call(name, args) {
  const result = await bridge.callServerTool({ name, arguments: args }, { timeout: 12000 });
  if (result.isError) throw new Error(result.content?.[0]?.text || t('Read failed.'));
  return result;
}
function displayModeControl() {
  document.querySelectorAll('[data-display-mode]').forEach(button => {
    button.disabled = changingDisplayMode || (availableDisplayModes && !availableDisplayModes.includes(button.dataset.displayMode));
    button.title = button.disabled && !changingDisplayMode ? t('This host does not support this display mode.') : '';
  });
  document.querySelectorAll('[data-expand-feature]').forEach(button => { button.disabled = changingDisplayMode || (availableDisplayModes && !availableDisplayModes.includes('fullscreen')); });
}
function applyAppearance() {
  locale = resolveLocale(preferences.language, hostContext.locale, navigator.language);
  document.documentElement.lang = locale;
  const theme = preferences.appearance === 'auto' ? hostContext.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : preferences.appearance;
  applyDocumentTheme(theme);
  document.documentElement.dataset.appearance = preferences.appearance;
}
function applyHostContext(context = {}) {
  hostContext = { ...hostContext, ...context };
  if (context.styles?.variables) applyHostStyleVariables(context.styles.variables);
  if (context.displayMode) displayMode = context.displayMode;
  if (context.availableDisplayModes) availableDisplayModes = context.availableDisplayModes;
  applyAppearance();
  if (state) render(); else displayModeControl();
}
async function requestDisplayMode(mode) {
  if (changingDisplayMode || (availableDisplayModes && !availableDisplayModes.includes(mode))) return;
  changingDisplayMode = true; displayModeControl();
  try {
    const result = await bridge.requestDisplayMode({ mode });
    displayMode = result.mode || displayMode;
    if (displayMode !== mode) say(t('The host kept the previous display mode.'));
  } catch { say(t('Unable to change display mode.')); }
  finally { changingDisplayMode = false; if (state) render(); }
}
function statusLine() {
  const label = !connected ? t('Connecting to host') : switching ? t('Loading project…') : error ? `${t('Stale')} · ${t('last checked')} ${stamp(lastRead)} · ${error}` : busy ? t('Checking for changes…') : `${t('Checked')} ${stamp(lastRead)} · ${t('auto refresh')} ${t(document.hidden ? 'paused' : 'every 4s')}`;
  const el = document.querySelector('#sync');
  if (el) { el.textContent = label; el.dataset.stale = String(Boolean(error)); }
  const button = document.querySelector('#refresh'); if (button) button.disabled = busy || switching;
  document.querySelectorAll('[data-project]').forEach(button => { button.disabled = busy || switching || button.dataset.available === 'false'; });
}
async function persistView(project, value) {
  try { await call('operator_console_save_view', { projectRoot: project.root, projectId: project.id, view: value }); }
  catch { say(t('View could not be saved.')); }
}
function saveView() {
  clearTimeout(saveTimer);
  if (!state || switching || restoringScroll) return;
  const project = state.project, value = view();
  views.set(project.id, value);
  saveTimer = setTimeout(() => persistView(project, value), 600);
}
function restoreScroll(y) {
  restoringScroll = true;
  requestAnimationFrame(() => { window.scrollTo(0, y || 0); requestAnimationFrame(() => { restoringScroll = false; }); });
}
function ingest(result, expectedRoot = state?.project.root || toolRoot, replace = false) {
  if (result?.isError) throw new Error(result.content?.[0]?.text || t('Read failed.'));
  const next = result?.structuredContent;
  if (next?.schemaVersion !== 'operator.console/v2' || !next.project?.id || !next.revision || !next.generatedAt) throw new Error(t('Invalid snapshot returned by Operator.'));
  // Explicit switching may rebind; ordinary refreshes may never do so.
  if (!replace && state && (state.project.id !== next.project.id || state.project.root !== next.project.root)) throw new Error(t('Project binding changed.'));
  if (replace && next.project.root !== expectedRoot) throw new Error(t('Project binding changed.'));
  if ((!state || replace) && next.unchanged) throw new Error(t('The initial snapshot was missing.'));
  if (!next.unchanged && (!Array.isArray(next.features) || !Array.isArray(next.attention))) throw new Error(t('Incomplete project snapshot.'));
  lastRead = next.generatedAt; error = ''; failures = 0;
  if (next.unchanged) { statusLine(); return; }
  const changed = state?.revision !== next.revision;
  state = next; toolRoot = next.project.root;
  if (!restored || replace) {
    const saved = views.get(state.project.id) || state.savedView;
    selectedId = saved?.selectedId || state.features[0]?.id; selectedTask = saved?.selectedTask || null;
    currentTab = saved?.tab || 'work'; restored = true;
    render(); restoreScroll(saved?.scrollY);
  } else if (changed) render();
  statusLine();
}
async function switchProject(projectRoot) {
  if (switching || busy || projectRoot === state?.project.root) return;
  clearTimeout(timer); clearTimeout(saveTimer);
  if (state) { const value = view(); views.set(state.project.id, value); void persistView(state.project, value); }
  switching = true; statusLine();
  try {
    const result = await call('operator_console_refresh', { projectRoot, capacity: 4 });
    ingest(result, projectRoot, true);
  } catch (e) { say(`${t('Could not switch project')}: ${e.message}`); }
  finally { switching = false; statusLine(); schedule(); }
}
async function loadProjects() {
  if (projectsBusy || !connected || !toolRoot) return;
  projectsBusy = true;
  try {
    const next = (await call('operator_console_projects', { projectRoot: toolRoot })).structuredContent;
    if (!Array.isArray(next?.projects)) throw new Error(t('Project list unavailable'));
    const changed = JSON.stringify(projects) !== JSON.stringify(next.projects) || projectsError;
    projects = next.projects; projectsAt = next.generatedAt; projectsError = '';
    if (!preferencesLoaded) { preferences = { ...preferences, ...next.preferences }; preferencesLoaded = true; applyAppearance(); if (state) render(); }
    else if (changed && preferences.allProjects && state) render();
    const time = document.querySelector('#projects-time'); if (time) time.textContent = `${t('Project list last checked')} ${stamp(projectsAt)}`;
  } catch (e) { projectsError = e.message; if (preferences.allProjects && state) render(); }
  finally { projectsBusy = false; }
}
function setPreferences(change) {
  preferences = { ...preferences, ...change }; preferencesLoaded = true;
  applyAppearance(); render();
  const saved = { ...preferences };
  settingsWrite = settingsWrite.then(() => call('operator_console_preferences', saved)).catch(() => say(t('Settings could not be saved.')));
  if (preferences.allProjects) void loadProjects();
}
function schedule() {
  clearTimeout(timer);
  if (connected && !document.hidden && state && !switching) timer = setTimeout(() => refresh(), Math.min(30000, 4000 * 2 ** Math.min(failures, 3)));
}
async function refresh(manual = false) {
  if (busy || switching || !connected || !toolRoot) return;
  busy = true; statusLine();
  try {
    ingest(await call('operator_console_refresh', { projectRoot: state?.project.root || toolRoot, projectId: state?.project.id, sinceRevision: state?.revision, capacity: 4 }));
    if (manual) say(`${t('Refresh completed')} ${stamp(lastRead)}.`);
  } catch (e) {
    error = e.message; failures++;
    if (!state) { root.innerHTML = `<section class="setup"><h1>${h('Unable to read this project')}</h1><p>${escape(error)}</p><button id="refresh">${h('Retry')}</button></section>`; document.querySelector('#refresh').onclick = () => refresh(true); }
  } finally { busy = false; statusLine(); schedule(); }
  if (preferences.allProjects || !preferencesLoaded) void loadProjects();
}
function featureCard(feature) {
  return `<div class="feature-card ${feature.id === selectedId ? 'selected' : ''}"><button class="feature-select" data-feature="${escape(feature.id)}" aria-pressed="${feature.id === selectedId}"><span class="feature-top"><span class="feature-id">${escape(feature.id)}</span><span class="status ${escape(feature.status)}">${h(feature.status)}</span></span><strong>${escape(feature.title)}</strong><span class="feature-meta">${h('Recorded tasks')}: ${number(feature.tasks.length)} · ${h('Completed')}: ${number(feature.tasks.filter(t => t.state === 'completed').length)}</span></button><button class="feature-expand" data-expand-feature="${escape(feature.id)}" aria-label="${h('Full screen')} ${escape(feature.id)}">${h('Full screen')}</button></div>`;
}
function taskDetail(feature) {
  const task = feature.tasks.find(t => t.id === selectedTask);
  if (!task) return `<p class="muted">${h(selectedTask ? 'Selected task unavailable' : 'Select a task to inspect its state and dependencies.')}</p>`;
  const fields = [['Recorded state', t(task.state)], ['Lane', task.lane || t('unassigned')], ['Approval', t(task.approval)], ['Dependencies', task.dependsOn.join(', ') || t('none')], ['Eligibility', task.eligible ? t('Selected by advisory frontier; execution is a separate action.') : task.reasons.join('; ') || t('Not selected by the current frontier.')], ['Evidence', `${t(task.source)} · ${number(feature.graphRevision)} · ${stamp(task.updatedAt)}`]];
  return `<div class="task-detail"><span class="eyebrow">${escape(task.id)}</span><h3>${escape(task.title)}</h3><dl>${fields.map(([key, value]) => `<dt>${h(key)}</dt><dd>${escape(value)}</dd>`).join('')}</dl></div>`;
}
function detail(feature) {
  if (!feature) return `<section class="panel empty"><h2>${h(selectedId ? 'Selected feature unavailable' : 'No feature sessions yet')}</h2><p>${h('Choose a feature from the project overview.')}</p></section>`;
  const content = currentTab === 'work' ? `<div class="nodes">${feature.tasks.length ? feature.tasks.map(task => `<button class="node-row ${task.id === selectedTask ? 'selected' : ''}" data-task="${escape(task.id)}" aria-pressed="${task.id === selectedTask}"><span class="node-copy"><strong>${escape(task.title)}</strong><small>${escape(task.lane || t('unassigned'))}</small></span><span class="status">${h(task.state)}</span></button>`).join('') : `<p class="muted">${h('No dependency graph tasks recorded.')}</p>`}</div>${taskDetail(feature)}` : currentTab === 'brief' ? `<pre class="record">${escape(feature.brief || t('No feature brief recorded.'))}</pre>` : `<div class="records">${feature.records.map(record => `<details data-record="${escape(record.name)}"><summary>${escape(record.name)}</summary><small>${escape(record.path)}</small><pre class="record">${escape(record.excerpt)}</pre></details>`).join('')}<p class="muted">${h('Source documents retain their original language.')}</p></div>`;
  return `<section class="detail panel"><div class="detail-head"><div><span class="eyebrow">${escape(feature.id)} · ${escape(feature.branch || t('no branch'))}</span><h2>${escape(feature.title)}</h2></div><div class="detail-controls"><span class="status ${escape(feature.status)}">${h(feature.status)}</span><button class="secondary" data-display-mode="fullscreen">${h('Full screen')}</button></div></div><p class="detail-meta">${h('Bound Codex tasks')}: ${number(feature.boundChats.length)} · ${escape(feature.worktree || t('No worktree recorded'))}</p><nav aria-label="${h('Feature detail')}">${['work', 'brief', 'records'].map(tab => `<button data-tab="${tab}" aria-pressed="${tab === currentTab}">${h(tab[0].toUpperCase() + tab.slice(1))}</button>`).join('')}</nav>${content}<div class="actions">${feature.boundChats.map((chat, i) => `<button class="secondary" data-chat="${escape(chat.id)}">${h('Open Codex task')}${feature.boundChats.length > 1 ? ` ${i + 1}` : ''}</button>`).join('') || `<span class="muted">${h('No Codex conversation bound.')}</span>`}</div><p class="safety">${h('Open task asks the host to navigate. It does not start work.')}</p></section>`;
}
function projectSidebar() {
  if (!preferences.allProjects) return '';
  return `<aside class="projects panel" aria-label="${h('Registered projects')}"><div class="section-head"><h2>${h('Registered projects')}</h2></div><p class="muted sidebar-note">${h('Only registered local projects are listed.')}</p>${projectsError ? `<p class="warning">${h('Project list unavailable')}: ${escape(projectsError)}</p>` : ''}<div>${projects.map(project => `<button class="project-row ${project.root === state.project.root ? 'selected' : ''}" data-project="${escape(project.root)}" data-available="${project.available}" aria-pressed="${project.root === state.project.root}"><strong>${escape(project.name)}</strong>${project.available ? `<span>${h('Need attention')}: ${number(project.summary.attention)} · ${h('Active')}: ${number(project.summary.active)}</span><small>${h('Last activity')}: ${stamp(project.lastActivity)}</small>` : `<span>${h('Unavailable')}</span><small>${escape(project.error)}</small>`}</button>`).join('')}</div><small id="projects-time">${h('Project list last checked')} ${stamp(projectsAt)}</small><details data-record="add-project"><summary>${h('Add project')}</summary><form id="add-project"><label>${h('Project root')}<input id="project-root-input" name="projectRoot" required placeholder="${h('Absolute folder containing operator.config.env')}" autocomplete="off"></label><button type="submit" class="secondary">${h('Add')}</button></form></details></aside>`;
}
function render() {
  const y = window.scrollY, focused = document.activeElement;
  const focusKey = ['id', 'data-feature', 'data-expand-feature', 'data-task', 'data-tab', 'data-chat', 'data-project'].map(key => [key, focused?.getAttribute(key)]).find(([, value]) => value);
  const expanded = [...document.querySelectorAll('details[open]')].map(el => el.dataset.record);
  const draft = document.querySelector('[name=projectRoot]')?.value || '';
  const setting = (id, label, values, current) => `<label>${h(label)}<select id="${id}">${values.map(([value, label]) => `<option value="${value}" ${value === current ? 'selected' : ''}>${h(label)}</option>`).join('')}</select></label>`;
  const mode = displayMode === 'inline' ? 'fullscreen' : 'inline';
  root.innerHTML = `<header><div class="brand"><span class="mark">o:</span>Operator <i>${h('Console')}</i><b>v6-alpha</b></div><div class="project"><strong>${escape(state.project.name)}</strong><span>${h('Local records')}</span></div><button id="projects-toggle" class="secondary" aria-pressed="${preferences.allProjects}">${h(preferences.allProjects ? 'Current project' : 'All projects')}</button><button id="expand" class="secondary" data-display-mode="${mode}">${h(mode === 'fullscreen' ? 'Expand' : 'Back to inline')}</button><button id="refresh" class="icon-button" aria-label="${h('Refresh')}">↻</button></header><section class="preferences" aria-label="${h('Appearance')}">${setting('language', 'Language', [['auto','Follow host'],['en','English'],['pl','Polski']], preferences.language)}${setting('appearance','Appearance',[['auto','Follow host'],['light','Light'],['dark','Dark']],preferences.appearance)}</section><div id="sync" role="status" aria-live="off"></div><div class="workspace ${preferences.allProjects ? 'with-projects' : ''}">${projectSidebar()}<main><section class="metrics"><div><strong>${number(state.summary.features)}</strong><span>${h('Feature sessions')}</span></div><div><strong>${number(state.summary.recordedActiveTasks)}</strong><span>${h('Tasks recorded active')}</span></div><div><strong>${number(state.summary.attention)}</strong><span>${h('Need attention')}</span></div><div><strong>${state.summary.eligibleTasks == null ? '—' : number(state.summary.eligibleTasks)}</strong><span>${h('Eligible · capacity 4')}</span></div></section><section class="panel attention"><div class="section-head"><h2>${h('Needs attention')}</h2><span>${h('Recorded Operator state')}</span></div>${state.attention.length ? state.attention.map(item => `<button class="attention-item" data-feature="${escape(item.featureId)}" data-select-task="${escape(item.taskId || '')}"><span>${escape(item.title)}</span><small>${item.reason.startsWith('Feature: ') ? `${h('Feature')}: ${h(item.reason.slice(9))}` : h(item.reason)}</small></button>`).join('') : `<p class="muted">${h('No recorded attention items.')}</p>`}</section><div class="layout"><aside class="feature-list panel"><div class="section-head"><h2>${h('Project overview')}</h2><span>${number(state.features.length)}</span></div>${state.features.map(featureCard).join('')}</aside>${detail(state.features.find(f => f.id === selectedId))}</div><section class="lanes panel"><div class="section-head"><h2>${h('Configured lanes')}</h2><span>${h('Worker activity unverified')}</span></div><div class="lane-grid">${state.lanes.map(lane => `<div class="lane"><div><strong>${escape(lane.id)}</strong><small>${escape(lane.owner)}</small></div><small>${h(lane.windowPresent === null ? 'window unknown' : lane.windowPresent ? 'window present' : 'no window')}</small></div>`).join('')}</div></section><section class="panel recent"><div class="section-head"><h2>${h('Recent recorded changes')}</h2><span>${h('Graph events')}</span></div>${state.features.flatMap(f => f.recentChanges || []).sort((a, b) => String(b.occurredAt).localeCompare(String(a.occurredAt))).slice(0, 6).map(event => `<p>${escape(event.featureId)} · ${escape(event.taskId)} · ${h(event.state || event.action)} <small>${stamp(event.occurredAt)}</small></p>`).join('') || `<p class="muted">${h('No graph events recorded yet.')}</p>`}</section>${!state.readiness.available ? `<p class="warning">${h('Eligibility unavailable')}: ${escape(state.readiness.reason)}</p>` : ''}</main></div><footer><span>${escape(state.project.root)}</span><span>${h('Revision')} ${state.revision.slice(0, 8)}</span></footer>`;
  document.querySelector('#refresh').onclick = () => refresh(true);
  document.querySelector('#projects-toggle').onclick = () => setPreferences({ allProjects: !preferences.allProjects });
  document.querySelector('#language').onchange = e => setPreferences({ language: e.target.value });
  document.querySelector('#appearance').onchange = e => setPreferences({ appearance: e.target.value });
  document.querySelectorAll('[data-display-mode]').forEach(button => button.onclick = () => requestDisplayMode(button.dataset.displayMode));
  document.querySelectorAll('[data-project]').forEach(button => button.onclick = () => switchProject(button.dataset.project));
  document.querySelectorAll('[data-feature]').forEach(button => button.onclick = () => { selectedId = button.dataset.feature; selectedTask = button.dataset.selectTask || null; render(); saveView(); });
  document.querySelectorAll('[data-expand-feature]').forEach(button => button.onclick = () => { selectedId = button.dataset.expandFeature; selectedTask = null; render(); saveView(); void requestDisplayMode('fullscreen'); });
  document.querySelectorAll('[data-task]').forEach(button => button.onclick = () => { selectedTask = button.dataset.task; render(); saveView(); });
  document.querySelectorAll('[data-tab]').forEach(button => button.onclick = () => { currentTab = button.dataset.tab; render(); saveView(); });
  document.querySelectorAll('[data-chat]').forEach(button => button.onclick = async () => {
    try {
      const result = await bridge.sendMessage({ role: 'user', content: [{ type: 'text', text: `Open the existing Codex task with ID ${button.dataset.chat}, bound to ${selectedId} in Operator project ${state.project.name}. Use host task navigation if available. This requests navigation only.` }] });
      if (result?.isError) throw new Error();
      say(t('Navigation request accepted by the host.'));
    } catch { say(t('Task navigation is unavailable in this host.')); }
  });
  const form = document.querySelector('#add-project');
  if (form) {
    form.elements.projectRoot.value = draft;
    form.onsubmit = async e => {
      e.preventDefault(); const button = form.querySelector('button'); button.disabled = true;
      try { await call('operator_console_register_project', { projectRoot: form.elements.projectRoot.value.trim() }); form.reset(); say(t('Project added')); await loadProjects(); }
      catch (error) { say(`${t('Could not add project')}: ${error.message}`); }
      finally { button.disabled = false; }
    };
  }
  for (const name of expanded) { const element = [...document.querySelectorAll('details')].find(el => el.dataset.record === name); if (element) element.open = true; }
  if (focusKey) [...document.querySelectorAll(`[${focusKey[0]}]`)].find(el => el.getAttribute(focusKey[0]) === focusKey[1])?.focus({ preventScroll: true });
  window.scrollTo(0, y); displayModeControl(); statusLine();
}
bridge.ontoolinput = input => { if (!state) { toolRoot = input.arguments?.projectRoot; if (connected) void refresh(); } };
bridge.ontoolresult = result => { if (!state) { try { ingest(result); schedule(); void loadProjects(); } catch (e) { error = e.message; statusLine(); } } };
bridge.onhostcontextchanged = applyHostContext;
document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (!document.hidden) void refresh(); statusLine(); });
window.addEventListener('focus', () => refresh());
window.addEventListener('scroll', () => saveView(), { passive: true });
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => applyAppearance());
try {
  await bridge.connect(); connected = true;
  applyHostContext(bridge.getHostContext() || {});
  statusLine();
  if (toolRoot && !state) await refresh(); else schedule();
  void loadProjects();
} catch (e) { root.innerHTML = `<section class="setup"><h1>${h('Host connection unavailable')}</h1><p>${escape(e.message)}</p><p>${h('This resource needs an MCP Apps host.')}</p></section>`; }
