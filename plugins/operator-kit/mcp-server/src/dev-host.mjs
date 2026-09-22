import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { projectInfo } from './state.mjs';

export async function serve(root, port = 43132, browserPort = port) {
  const project = projectInfo(root);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Choose a port from 1024 to 65535.');
  if (!Number.isInteger(browserPort) || browserPort < 1024 || browserPort > 65535) throw new Error('Choose a browser port from 1024 to 65535.');
  const origin = `http://127.0.0.1:${port}`, token = randomBytes(24).toString('hex');
  // SSH forwarding preserves the browser's Host and Origin. Admit only the
  // explicitly configured loopback ports and require each POST to match its Host.
  const browserOrigins = new Map([port, browserPort].map(value => [`127.0.0.1:${value}`, `http://127.0.0.1:${value}`]));
  const client = new Client({ name: 'Operator v6-alpha development host', version: '0.6.0-alpha.1' });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('./server.mjs', import.meta.url))], env: { ...process.env } }));
  const tools = (await client.listTools()).tools;
  const resourceUri = tools.find(tool => tool.name === 'operator_console')._meta.ui.resourceUri;
  const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Operator v6-alpha</title><style>body{margin:0;font:13px system-ui;background:#f4f5f7;color:#18202a}header{display:flex;align-items:center;gap:16px;padding:12px 18px;flex-wrap:wrap}small{color:#66717e}label{display:flex;gap:7px;align-items:center}select,button{font:inherit;padding:5px}iframe{display:block;width:100%;height:calc(100vh - 95px);border:0}#receipt{padding:6px 18px;font-size:11px}body[data-mode=inline] iframe{max-width:900px;margin:auto}</style></head><body><header><strong>Operator v6-alpha</strong><small>Local development host · real MCP connection</small><label>Host theme <select id="host-theme"><option>light</option><option>dark</option></select></label><label>Host language <select id="host-locale"><option value="en-US">English</option><option value="pl-PL">Polski</option></select></label><button id="connection">Simulate disconnection</button></header><div id="receipt" role="status">Connecting…</div><iframe title="Operator cockpit" sandbox="allow-scripts"></iframe><script id="config" type="application/json">${JSON.stringify({ token })}</script><script type="module" src="/host.js"></script></body></html>`;
  const allowed = new Set(tools.map(tool => tool.name));
  const server = createServer(async (req, res) => {
    try {
      const requestOrigin = browserOrigins.get(req.headers.host);
      if (!requestOrigin) { res.writeHead(403); return res.end(); }
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      const url = new URL(req.url, origin);
      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/preview.html' || url.pathname === '/embedded')) {
        res.setHeader('Content-Type', 'text/html'); res.setHeader('Content-Security-Policy', "frame-ancestors 'none'");
        if (url.pathname === '/embedded') return res.end(page);
        const web = await readFile(new URL('./web.html', import.meta.url), 'utf8');
        return res.end(web.replace('<!-- WEB_CONFIG -->', () => `<script id="config" type="application/json">${JSON.stringify({ token })}</script>`));
      }
      if (req.method === 'GET' && url.pathname === '/host.js') { res.setHeader('Content-Type', 'text/javascript'); return res.end(await readFile(new URL('./host.js', import.meta.url))); }
      if (req.method === 'GET' && url.pathname === '/resource') { res.setHeader('Content-Type', 'text/html'); return res.end((await client.readResource({ uri: resourceUri })).contents[0].text); }
      if (req.method === 'GET' && url.pathname === '/favicon.ico') { res.writeHead(204); return res.end(); }
      res.setHeader('Content-Type', 'application/json');
      if (req.headers['x-operator-token'] !== token) { res.writeHead(403); return res.end('{}'); }
      if (req.method === 'GET' && url.pathname === '/initial') return res.end(JSON.stringify({ root: project.root, result: await client.callTool({ name: 'operator_console', arguments: { projectRoot: project.root } }) }));
      if (req.method === 'POST' && url.pathname === '/rpc') {
        if (req.headers.origin !== requestOrigin) { res.writeHead(403); return res.end(JSON.stringify({ isError: true, content: [{ type: 'text', text: 'Invalid origin' }] })); }
        let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 32000) throw new Error('Request too large'); }
        const call = JSON.parse(body);
        if (!allowed.has(call.name)) throw new Error('Unknown console tool');
        return res.end(JSON.stringify(await client.callTool(call)));
      }
      res.writeHead(404); res.end('{}');
    } catch (error) { res.writeHead(400); res.end(JSON.stringify({ isError: true, content: [{ type: 'text', text: error.message }] })); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); }).catch(async e => { await client.close(); throw e; });
  console.log(`Operator v6-alpha: ${origin}`);
  if (browserPort !== port) console.log(`Allowed SSH browser address: http://127.0.0.1:${browserPort}`);
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { server.close(); await client.close(); process.exit(0); });
}
