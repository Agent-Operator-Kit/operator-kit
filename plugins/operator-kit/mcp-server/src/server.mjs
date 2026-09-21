import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { readFile } from 'node:fs/promises';
import { z } from 'zod';
import { snapshot, saveView } from './state.mjs';

const RESOURCE_URI = 'ui://operator/console-v2.html';
const server = new McpServer({ name: 'operator-console', version: '0.6.0' });
const inputSchema = {
  projectRoot: z.string().describe('Exact absolute project root containing operator.config.env; required on every call.'),
  projectId: z.string().optional().describe('Expected project ID from the initial snapshot; prevents accidental rebinding.'),
  sinceRevision: z.string().optional().describe('Last received revision; unchanged reads return only a receipt.'),
  capacity: z.number().int().min(0).max(100).default(4).describe('Explicit advisory frontier capacity; never dispatches work.')
};
const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
async function read(args) {
  try {
    const state = snapshot(args.projectRoot, args.capacity);
    if (args.projectId && args.projectId !== state.project.id) throw new Error('Project identity changed. Reopen the intended project explicitly.');
    const unchanged = args.sinceRevision === state.revision;
    const structuredContent = unchanged ? { schemaVersion: state.schemaVersion, unchanged: true, project: state.project, revision: state.revision, generatedAt: state.generatedAt } : state;
    return { content: [{ type: 'text', text: `${state.project.name}: ${state.summary.features} features; ${state.summary.attention} attention items. ${unchanged ? 'No recorded changes.' : 'Snapshot read.'}` }], structuredContent };
  } catch (error) { return { isError: true, content: [{ type: 'text', text: error.message }] }; }
}
registerAppTool(server, 'operator_console', {
  title: 'Open Operator cockpit', description: 'Open one project cockpit. Always pass the initialized Operator workspace root; source worktrees may live below it.', inputSchema, annotations,
  _meta: { ui: { resourceUri: RESOURCE_URI, visibility: ['app', 'model'] } }
}, args => read({ ...args, sinceRevision: undefined }));
server.registerTool('operator_console_refresh', {
  title: 'Read Operator cockpit state', description: 'Read or poll the same bound project without creating another UI card. Returns an acknowledged snapshot or unchanged revision.', inputSchema, annotations,
  _meta: { ui: { visibility: ['app', 'model'] } }
}, read);
server.registerTool('operator_console_save_view', {
  title: 'Remember Operator cockpit view', description: 'Save only this local user’s project cockpit selection, tab and scroll position. Does not change tasks or dispatch work.',
  inputSchema: { projectRoot: inputSchema.projectRoot, projectId: z.string(), view: z.object({ selectedId: z.string().nullable(), selectedTask: z.string().nullable(), tab: z.enum(['work', 'brief', 'records']), scrollY: z.number().min(0).max(1000000) }).strict() },
  annotations: { ...annotations, readOnlyHint: false }, _meta: { ui: { visibility: ['app'] } }
}, async args => {
  try {
    const state = snapshot(args.projectRoot);
    if (state.project.id !== args.projectId) throw new Error('Project identity mismatch.');
    saveView(state.project, args.view);
    return { content: [{ type: 'text', text: 'Cockpit view saved.' }], structuredContent: { saved: true, projectId: state.project.id } };
  } catch (e) { return { isError: true, content: [{ type: 'text', text: e.message }] }; }
});
registerAppResource(server, 'Operator cockpit', RESOURCE_URI, { mimeType: RESOURCE_MIME_TYPE }, async () => ({ contents: [{ uri: RESOURCE_URI, mimeType: RESOURCE_MIME_TYPE, text: await readFile(new URL('../dist/console.html', import.meta.url), 'utf8'), _meta: { ui: { prefersBorder: true, csp: { connectDomains: [], resourceDomains: [] } } } }] }));
await server.connect(new StdioServerTransport());
