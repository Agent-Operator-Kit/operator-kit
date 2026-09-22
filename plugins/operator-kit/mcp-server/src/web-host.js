// Browser-only host: the same App and UI run in the top-level document so
// inspection and annotations can target the actual cockpit elements.
import { AppBridge } from '@modelcontextprotocol/ext-apps/app-bridge';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

export async function connectWebHost(app) {
  const { token } = JSON.parse(document.querySelector('#config').textContent);
  const headers = { 'Content-Type': 'application/json', 'X-Operator-Token': token };
  async function request(path, body) {
    const response = await fetch(path, { headers, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(12000) });
    if (!response.ok) throw new Error(`Preview request failed (${response.status}). Reload the page if the server restarted.`);
    return response.json();
  }
  const initial = await request('/initial');
  const appearance = matchMedia('(prefers-color-scheme: dark)');
  const host = new AppBridge(null, { name: 'Operator web preview', version: '0.6.0-alpha.1' }, { serverTools: {} }, {
    hostContext: { theme: appearance.matches ? 'dark' : 'light', locale: navigator.language, displayMode: 'fullscreen', availableDisplayModes: ['inline', 'fullscreen'] }
  });
  host.oncalltool = params => request('/rpc', params);
  host.oninitialized = async () => { await host.sendToolInput({ arguments: { projectRoot: initial.root } }); await host.sendToolResult(initial.result); };
  host.onmessage = async () => ({ isError: true });
  host.onrequestdisplaymode = async ({ mode }) => { document.documentElement.dataset.previewMode = mode; host.setHostContext({ displayMode: mode }); return { mode }; };
  host.onsizechange = () => {};
  appearance.addEventListener('change', () => host.setHostContext({ theme: appearance.matches ? 'dark' : 'light' }));
  const [hostTransport, appTransport] = InMemoryTransport.createLinkedPair();
  await host.connect(hostTransport);
  await app.connect(appTransport);
}
