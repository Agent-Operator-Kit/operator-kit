import { App, applyDocumentTheme, applyHostFonts, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';

const root = document.querySelector('#app');
const notice = document.querySelector('#notice');
const bridge = new App({ name: 'Operator Console', version: '0.6.0' }, { availableDisplayModes: ['inline', 'fullscreen'] });
let state = null;
let selectedId = null;
let busy = false;

const escape = value => String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const stamp = value => value ? new Date(value).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : 'No activity';

function toast(message, error = false) {
  notice.textContent = message;
  notice.className = error ? 'show error' : 'show';
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { notice.className = ''; }, 4200);
}

function ingest(result) {
  if (!result?.structuredContent?.schemaVersion) return;
  state = result.structuredContent;
  if (state.initialized && !state.features.some(feature => feature.id === selectedId)) selectedId = state.features[0]?.id || null;
  render();
}

async function refresh() {
  if (busy) return;
  busy = true;
  render();
  try {
    const result = await bridge.callServerTool({ name: 'operator_console_refresh', arguments: { projectRoot: state?.project?.root } });
    if (result.isError) throw new Error(result.content?.[0]?.text || 'Refresh failed.');
    ingest(result);
    toast('Operator state refreshed.');
  } catch (error) { toast(error.message, true); }
  finally { busy = false; render(); }
}

async function ask(prompt) {
  try {
    const result = await bridge.sendMessage({ role: 'user', content: [{ type: 'text', text: prompt }] });
    if (result?.isError) throw new Error('Codex did not accept the request.');
    toast('Request added to this conversation.');
  } catch (error) { toast(error.message, true); }
}

function mark() { return '<span class="mark" aria-hidden="true">o<span>:</span></span>'; }

function featureCard(feature) {
  const total = feature.graph.nodes.length;
  const completed = feature.graph.counts.completed || 0;
  const progress = total ? Math.round(completed / total * 100) : 0;
  return `<button class="feature-card ${feature.id === selectedId ? 'selected' : ''}" data-feature="${escape(feature.id)}">
    <span class="feature-top"><span class="feature-id">${escape(feature.id)}</span><span class="status ${escape(feature.status)}">${escape(feature.status)}</span></span>
    <strong>${escape(feature.title)}</strong>
    <span class="progress"><i style="width:${progress}%"></i></span>
    <span class="feature-meta"><span>${completed}/${total || '—'} complete</span><span>${feature.graph.runnable.length} runnable</span></span>
  </button>`;
}

function nodeRow(node, feature) {
  const runnable = feature.graph.runnable.includes(node.id);
  return `<div class="node-row">
    <span class="node-state ${escape(node.state)}">${node.state === 'completed' ? '✓' : runnable ? '→' : '·'}</span>
    <span class="node-copy"><strong>${escape(node.title || node.id)}</strong><small>${escape(node.id)} · ${escape(node.lane || 'unassigned')}</small></span>
    <span class="node-tags">${runnable ? '<b>runnable</b>' : ''}${node.approval === 'pending' ? '<em>approval</em>' : ''}</span>
  </div>`;
}

function detail(feature) {
  if (!feature) return '<section class="empty panel"><h2>No active features</h2><p>Operator is initialized, but no active feature sessions were found.</p></section>';
  const next = feature.graph.nodes.filter(node => feature.graph.runnable.includes(node.id));
  return `<section class="detail panel">
    <div class="detail-head"><div><span class="eyebrow">${escape(feature.id)} · ${escape(feature.branch || 'no branch')}</span><h2>${escape(feature.title)}</h2></div><span class="status ${escape(feature.status)}">${escape(feature.status)}</span></div>
    <div class="detail-meta"><span>Updated ${escape(stamp(feature.updatedAt))}</span><span>${feature.boundChats.length} bound chat${feature.boundChats.length === 1 ? '' : 's'}</span><span>${feature.roles.length} role${feature.roles.length === 1 ? '' : 's'}</span></div>
    <div class="section-head"><h3>Dependency graph</h3><span>revision ${feature.graph.revision}</span></div>
    <div class="nodes">${feature.graph.nodes.length ? feature.graph.nodes.map(node => nodeRow(node, feature)).join('') : '<p class="muted">No graph has been created for this feature.</p>'}</div>
    <div class="actions">
      <button class="primary" id="ask-plan" ${!next.length ? 'disabled' : ''}>Plan next runnable task</button>
      <button class="secondary" id="ask-status">Explain this feature</button>
    </div>
    <p class="safety">These buttons send a request into this Codex conversation. They do not dispatch, merge, or modify the project by themselves.</p>
  </section>`;
}

function initialized() {
  const feature = state.features.find(item => item.id === selectedId);
  return `<header>
    <div class="brand">${mark()}<span>Operator <i>Console</i></span><b>EMBEDDED</b></div>
    <div class="project"><strong>${escape(state.project.name)}</strong><span>Kit ${escape(state.project.kitVersion)} · read-only</span></div>
    <button class="icon-button" id="refresh" aria-label="Refresh" title="Refresh" ${busy ? 'disabled' : ''}>${busy ? '…' : '↻'}</button>
  </header>
  <main>
    <section class="metrics">
      <div><strong>${state.summary.activeFeatures}</strong><span>Active features</span></div>
      <div><strong>${state.summary.runnableTasks}</strong><span>Runnable tasks</span></div>
      <div><strong>${state.summary.runningLanes}</strong><span>Running lanes</span></div>
      <div><strong>${state.summary.pendingApprovals}</strong><span>Approvals waiting</span></div>
    </section>
    <div class="layout">
      <aside class="feature-list panel"><div class="section-head"><h2>Feature sessions</h2><span>${state.features.length}</span></div>${state.features.map(featureCard).join('')}</aside>
      ${detail(feature)}
    </div>
    <section class="lanes panel"><div class="section-head"><h2>Worker lanes</h2><span>${state.lanes.filter(lane => lane.running).length} live</span></div><div class="lane-grid">${state.lanes.map(lane => `<div class="lane"><span class="live ${lane.running ? 'on' : ''}"></span><div><strong>${escape(lane.id)}</strong><small>${escape(lane.owner)}</small></div><code>${escape(lane.provider)}</code></div>`).join('')}</div></section>
    <section class="conflicts panel"><div class="section-head"><h2>Coordination check</h2><button class="text-button" id="ask-conflicts">Ask Codex to review</button></div><pre>${escape(state.conflicts || 'No conflict summary is available.')}</pre></section>
  </main>
  <footer><span>${escape(state.project.root)}</span><span>MCP App → Operator project state</span></footer>`;
}

function uninitialized() {
  return `<div class="setup"><div class="brand">${mark()}<span>Operator <i>Console</i></span></div><h1>Open an initialized Operator project</h1><p>${escape(state.message)}</p><code>${escape(state.searchedFrom)}</code><button class="primary" id="ask-setup">Set up Operator here</button></div>`;
}

function bind() {
  document.querySelector('#refresh')?.addEventListener('click', refresh);
  document.querySelectorAll('[data-feature]').forEach(button => button.addEventListener('click', () => { selectedId = button.dataset.feature; render(); }));
  document.querySelector('#ask-plan')?.addEventListener('click', () => ask(`Using Operator, inspect ${selectedId} in ${state.project.root}. Propose the next runnable task and wait for my approval before dispatching it.`));
  document.querySelector('#ask-status')?.addEventListener('click', () => ask(`Using Operator, explain the current status, blockers, and next decision for ${selectedId} in ${state.project.root}.`));
  document.querySelector('#ask-conflicts')?.addEventListener('click', () => ask(`Using Operator, review active feature conflicts in ${state.project.root} and recommend any coordination needed. Do not dispatch work.`));
  document.querySelector('#ask-setup')?.addEventListener('click', () => ask('Using Operator, inspect this workspace and guide me through the correct project setup. Do not install or change files until you show me the plan.'));
}

function render() {
  if (!state) return;
  root.innerHTML = state.initialized ? initialized() : uninitialized();
  bind();
}

bridge.ontoolresult = ingest;
bridge.onhostcontextchanged = context => {
  if (context.theme) applyDocumentTheme(context.theme);
  if (context.styles?.variables) applyHostStyleVariables(context.styles.variables);
  if (context.styles?.css?.fonts) applyHostFonts(context.styles.css.fonts);
};

try {
  await bridge.connect();
  const context = bridge.getHostContext();
  if (context?.theme) applyDocumentTheme(context.theme);
  if (context?.styles?.variables) applyHostStyleVariables(context.styles.variables);
  if (context?.styles?.css?.fonts) applyHostFonts(context.styles.css.fonts);
  setTimeout(async () => {
    if (state) return;
    try { ingest(await bridge.callServerTool({ name: 'operator_console_refresh', arguments: {} })); }
    catch (error) { root.innerHTML = `<div class="setup"><h1>Operator Console unavailable</h1><p>${escape(error.message)}</p></div>`; }
  }, 250);
} catch (error) {
  root.innerHTML = `<div class="setup"><h1>This host did not start the MCP App</h1><p>${escape(error.message)}</p></div>`;
}
