import { App, applyDocumentTheme, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';

const root = document.querySelector('#app');
const notice = document.querySelector('#notice');
const bridge = new App({ name: 'Operator Console POC', version: '0.6.0' }, { availableDisplayModes: ['inline', 'fullscreen'] });
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const stamp = value => value ? new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : 'not yet';
let state, selectedId, selectedTask, timer, busy = false, failures = 0, lastRead, connected = false, requestSequence = 0, saveTimer, restored = false;
let currentTab = 'work';
let error = '';
let toolRoot;
let displayMode = 'inline', availableDisplayModes, changingDisplayMode = false;
const view = () => ({ selectedId: selectedId || null, selectedTask: selectedTask || null, tab: currentTab, scrollY: window.scrollY });

function say(message) { notice.textContent = message; notice.className = 'show'; clearTimeout(say.timer); say.timer = setTimeout(() => { notice.className = ''; }, 6000); }
function displayModeControl() {
  const target = displayMode === 'inline' ? 'fullscreen' : 'inline';
  const supported = !availableDisplayModes || availableDisplayModes.includes(target);
  document.querySelectorAll('[data-display-mode]').forEach(button => {
    button.textContent = changingDisplayMode ? 'Switching…' : target === 'inline' ? 'Back to inline' : button.id === 'expand' ? 'Expand' : 'View full screen';
    button.disabled = changingDisplayMode || !supported;
    button.title = supported ? '' : 'This host does not support this display mode.';
  });
}
function applyHostContext(context = {}) {
  if (context.theme) applyDocumentTheme(context.theme);
  if (context.styles?.variables) applyHostStyleVariables(context.styles.variables);
  if (context.displayMode) displayMode = context.displayMode;
  if (context.availableDisplayModes) availableDisplayModes = context.availableDisplayModes;
  displayModeControl();
}
async function toggleDisplayMode() {
  if (changingDisplayMode) return;
  const mode = displayMode === 'inline' ? 'fullscreen' : 'inline';
  if (availableDisplayModes && !availableDisplayModes.includes(mode)) return;
  changingDisplayMode = true; displayModeControl();
  try {
    const result = await bridge.requestDisplayMode({ mode });
    // The host may keep the current mode instead of accepting our request.
    if (result.mode) displayMode = result.mode;
    if (displayMode !== mode) say(mode === 'inline' ? 'The host kept the console expanded.' : 'The host did not expand the console.');
  } catch { say(mode === 'inline' ? 'Unable to return to inline in this host.' : 'Unable to expand in this host.'); }
  finally { changingDisplayMode = false; displayModeControl(); }
}
function statusLine() {
  const label = !connected ? 'Connecting to host' : error ? `Stale · last checked ${stamp(lastRead)} · ${error}` : busy ? 'Checking for changes…' : `Checked ${stamp(lastRead)} · auto refresh ${document.hidden ? 'paused' : 'every 4s'}`;
  const el = document.querySelector('#sync');
  if (el) { el.textContent = label; el.dataset.stale = String(Boolean(error)); }
  const button = document.querySelector('#refresh');
  if (button) button.disabled = busy;
}
function saveView() {
  clearTimeout(saveTimer);
  if (!state) return;
  window.openai?.setWidgetState?.({ projectId: state.project.id, ...view() });
  saveTimer = setTimeout(async () => {
    try {
      const result = await bridge.callServerTool({ name: 'operator_console_save_view', arguments: { projectRoot: state.project.root, projectId: state.project.id, view: view() } });
      if (result.isError) throw new Error(result.content?.[0]?.text);
    } catch { say('View could not be saved. Current selection is still available while this view is open.'); }
  }, 600);
}
function ingest(result) {
  if (result?.isError) throw new Error(result.content?.[0]?.text || 'Read failed.');
  const next = result?.structuredContent;
  if (next?.schemaVersion !== 'operator.console/v2' || !next.project?.id || !next.revision || !next.generatedAt) throw new Error('Invalid snapshot returned by Operator.');
  if (state && (state.project.id !== next.project.id || state.project.root !== next.project.root)) throw new Error('Project binding changed. Reopen the intended project.');
  if (!state && next.unchanged) throw new Error('The initial snapshot was missing.');
  if (!next.unchanged && (!Array.isArray(next.features) || !Array.isArray(next.attention))) throw new Error('Incomplete project snapshot.');
  lastRead = next.generatedAt;
  error = '';
  failures = 0;
  if (next.unchanged) { statusLine(); return; }
  const changed = state?.revision !== next.revision;
  state = next;
  if (!restored) {
    const stored = window.openai?.widgetState;
    const saved = stored?.projectId === state.project.id ? stored : state.savedView;
    selectedId = saved?.selectedId || state.features[0]?.id;
    selectedTask = saved?.selectedTask || null;
    currentTab = saved?.tab || 'work';
    restored = true;
    render();
    requestAnimationFrame(() => window.scrollTo(0, saved?.scrollY || 0));
  } else if (changed) render();
  statusLine();
}
function schedule() {
  clearTimeout(timer);
  if (!connected || document.hidden || !state) return;
  timer = setTimeout(() => refresh(), Math.min(30000, 4000 * 2 ** Math.min(failures, 3)));
}
async function refresh(manual = false) {
  if (busy || !connected || !toolRoot) return;
  busy = true; const sequence = ++requestSequence; statusLine();
  try {
    const result = await bridge.callServerTool({ name: 'operator_console_refresh', arguments: { projectRoot: state?.project.root || toolRoot, projectId: state?.project.id, sinceRevision: state?.revision, capacity: 4 } }, { timeout: 12000 });
    if (sequence !== requestSequence) return;
    ingest(result);
    if (manual) say(`Refresh completed at ${stamp(lastRead)}.`);
  } catch (e) {
    error = e.message; failures++;
    if (!state) {
      root.innerHTML = `<section class="setup"><h1>Unable to read this project</h1><p>${escape(error)}</p><button id="refresh">Retry</button></section>`;
      document.querySelector('#refresh').onclick = () => refresh(true);
    }
  } finally { busy = false; statusLine(); schedule(); }
}
function featureCard(feature) {
  return `<button class="feature-card ${feature.id === selectedId ? 'selected' : ''}" data-feature="${escape(feature.id)}" aria-pressed="${feature.id === selectedId}"><span class="feature-top"><span class="feature-id">${escape(feature.id)}</span><span class="status ${escape(feature.status)}">${escape(feature.status)}</span></span><strong>${escape(feature.title)}</strong><span class="feature-meta">${feature.tasks.length} recorded tasks · ${feature.tasks.filter(t => t.state === 'completed').length} completed</span></button>`;
}
function taskDetail(feature) {
  const task = feature.tasks.find(t => t.id === selectedTask);
  if (selectedTask && !task) return '<p class="muted">The selected task is no longer in the latest record.</p>';
  if (!task) return '<p class="muted">Select a recorded task to inspect its state and dependencies.</p>';
  return `<div class="task-detail"><span class="eyebrow">${escape(task.id)}</span><h3>${escape(task.title)}</h3><dl><dt>Recorded state</dt><dd>${escape(task.state)}</dd><dt>Lane</dt><dd>${escape(task.lane || 'unassigned')}</dd><dt>Approval</dt><dd>${escape(task.approval)}</dd><dt>Dependencies</dt><dd>${escape(task.dependsOn.join(', ') || 'none')}</dd><dt>Eligibility</dt><dd>${task.eligible ? 'Selected by advisory frontier; execution is a separate action.' : escape(task.reasons.join('; ') || 'Not selected by the current frontier.')}</dd><dt>Evidence</dt><dd>${escape(task.source)} · revision ${feature.graphRevision} · ${stamp(task.updatedAt)}</dd></dl></div>`;
}
function detail(feature) {
  if (!feature) return `<section class="panel empty"><h2>${selectedId ? 'Selected feature unavailable' : 'No feature sessions yet'}</h2><p>Choose a feature from the project overview when one is available.</p></section>`;
  const tabs = ['work', 'brief', 'records'];
  const content = currentTab === 'work' ? `<div class="nodes">${feature.tasks.length ? feature.tasks.map(task => `<button class="node-row ${task.id === selectedTask ? 'selected' : ''}" data-task="${escape(task.id)}" aria-pressed="${task.id === selectedTask}"><span class="node-copy"><strong>${escape(task.title)}</strong><small>${escape(task.lane || 'unassigned')}</small></span><span class="status">${escape(task.state)}</span></button>`).join('') : '<p class="muted">No dependency graph tasks have been recorded for this feature.</p>'}</div>${taskDetail(feature)}` : currentTab === 'brief' ? `<pre class="record">${escape(feature.brief || 'No feature brief recorded.')}</pre>` : `<div class="records">${feature.records.map(record => `<details data-record="${escape(record.name)}"><summary>${escape(record.name)}</summary><small>${escape(record.path)}</small><pre class="record">${escape(record.excerpt)}</pre></details>`).join('')}<p class="muted">Local source documents. Shared knowledge and session questions are not connected in this POC.</p></div>`;
  return `<section class="detail panel"><div class="detail-head"><div><span class="eyebrow">${escape(feature.id)} · ${escape(feature.branch || 'no branch')}</span><h2>${escape(feature.title)}</h2></div><div class="detail-controls"><span class="status">${escape(feature.status)}</span><button class="secondary" data-display-mode>View full screen</button></div></div><p class="detail-meta">${feature.boundChats.length} bound Codex task(s) · ${escape(feature.worktree || 'No worktree recorded')}</p><nav aria-label="Feature detail">${tabs.map(tab => `<button data-tab="${tab}" aria-pressed="${tab === currentTab}">${tab[0].toUpperCase() + tab.slice(1)}</button>`).join('')}</nav>${content}<div class="actions">${feature.boundChats.map((chat, i) => `<button class="secondary" data-chat="${escape(chat.id)}">Open Codex task${feature.boundChats.length > 1 ? ` ${i + 1}` : ''}</button>`).join('') || '<span class="muted">No Codex conversation bound.</span>'}</div><p class="safety">Open task asks the host conversation to navigate. It does not start work.</p></section>`;
}
function render() {
  const y = window.scrollY;
  const focused = document.activeElement;
  const focusKey = ['id', 'data-feature', 'data-task', 'data-tab', 'data-chat'].map(key => [key, focused?.getAttribute(key)]).find(([, value]) => value);
  const expanded = [...document.querySelectorAll('details[open]')].map(el => el.dataset.record);
  root.innerHTML = `<header><div class="brand"><span class="mark">o:</span>Operator <i>Console</i><b>POC</b></div><div class="project"><strong>${escape(state.project.name)}</strong><span>Kit ${escape(state.project.kitVersion)} · local records</span></div><button id="expand" class="secondary" data-display-mode>Expand</button><button id="refresh" class="icon-button" aria-label="Refresh">↻</button></header><div id="sync" role="status" aria-live="off"></div><main><section class="metrics"><div><strong>${state.summary.features}</strong><span>Feature sessions</span></div><div><strong>${state.summary.recordedActiveTasks}</strong><span>Tasks recorded active</span></div><div><strong>${state.summary.attention}</strong><span>Need attention</span></div><div><strong>${state.summary.eligibleTasks ?? '—'}</strong><span>Eligible · capacity 4</span></div></section><section class="panel attention"><div class="section-head"><h2>Needs attention</h2><span>Recorded Operator state</span></div>${state.attention.length ? state.attention.map(item => `<button class="attention-item" data-feature="${escape(item.featureId)}" data-select-task="${escape(item.taskId || '')}"><span>${escape(item.title)}</span><small>${escape(item.reason)}</small></button>`).join('') : '<p class="muted">No recorded attention items.</p>'}</section><div class="layout"><aside class="feature-list panel"><div class="section-head"><h2>Project overview</h2><span>${state.features.length}</span></div>${state.features.map(featureCard).join('')}</aside>${detail(state.features.find(f => f.id === selectedId))}</div><section class="lanes panel"><div class="section-head"><h2>Configured lanes</h2><span>Worker activity unverified</span></div><div class="lane-grid">${state.lanes.map(lane => `<div class="lane"><div><strong>${escape(lane.id)}</strong><small>${escape(lane.owner)}</small></div><small>${lane.windowPresent === null ? 'window unknown' : lane.windowPresent ? 'window present' : 'no window'}</small></div>`).join('')}</div></section><section class="panel recent"><div class="section-head"><h2>Recent recorded changes</h2><span>Graph events</span></div>${state.features.flatMap(f => f.recentChanges || []).sort((a, b) => String(b.occurredAt).localeCompare(String(a.occurredAt))).slice(0, 6).map(event => `<p>${escape(event.featureId)} · ${escape(event.taskId)} · ${escape(event.state || event.action)} <small>${stamp(event.occurredAt)}</small></p>`).join('') || '<p class="muted">No graph events recorded yet.</p>'}</section>${!state.readiness.available ? `<p class="warning">Eligibility unavailable: ${escape(state.readiness.reason)}</p>` : ''}</main><footer><span>${escape(state.project.root)}</span><span>Revision ${state.revision.slice(0, 8)}</span></footer>`;
  document.querySelector('#refresh').onclick = () => refresh(true);
  document.querySelectorAll('[data-display-mode]').forEach(button => button.onclick = toggleDisplayMode);
  displayModeControl();
  document.querySelectorAll('[data-feature]').forEach(button => button.onclick = () => { selectedId = button.dataset.feature; selectedTask = button.dataset.selectTask || null; render(); saveView(); });
  document.querySelectorAll('[data-task]').forEach(button => button.onclick = () => { selectedTask = button.dataset.task; render(); saveView(); });
  document.querySelectorAll('[data-tab]').forEach(button => button.onclick = () => { currentTab = button.dataset.tab; render(); saveView(); });
  document.querySelectorAll('[data-chat]').forEach(button => button.onclick = async () => {
    try {
      const result = await bridge.sendMessage({ role: 'user', content: [{ type: 'text', text: `Open the existing Codex task with ID ${button.dataset.chat}, bound to ${selectedId} in Operator project ${state.project.name}. Use host task navigation if available. This requests navigation only.` }] });
      if (result?.isError) throw new Error();
      say('Navigation request accepted by the host.');
    } catch { say('Task navigation is unavailable in this host.'); }
  });
  for (const name of expanded) { const element = [...document.querySelectorAll('details')].find(el => el.dataset.record === name); if (element) element.open = true; }
  if (focusKey) [...document.querySelectorAll(`[${focusKey[0]}]`)].find(el => el.getAttribute(focusKey[0]) === focusKey[1])?.focus({ preventScroll: true });
  window.scrollTo(0, y); statusLine();
}
bridge.ontoolinput = input => { toolRoot = input.arguments?.projectRoot; if (connected && !state) refresh(); };
bridge.ontoolresult = result => { try { ingest(result); toolRoot = state.project.root; schedule(); } catch (e) { error = e.message; statusLine(); } };
bridge.onhostcontextchanged = applyHostContext;
document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (!document.hidden) refresh(); statusLine(); });
window.addEventListener('focus', () => refresh());
window.addEventListener('scroll', () => saveView(), { passive: true });
try {
  await bridge.connect(); connected = true;
  const context = bridge.getHostContext();
  applyHostContext(context || {});
  statusLine();
  if (toolRoot && !state) refresh(); else schedule();
} catch (e) { root.innerHTML = `<section class="setup"><h1>Host connection unavailable</h1><p>${escape(e.message)}</p><p>This resource needs an MCP Apps host.</p></section>`; }
