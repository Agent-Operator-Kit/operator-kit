#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { registerProject, listProjects, registryPath } from './projects.mjs';
const [command, ...args] = process.argv.slice(2);
try {
  switch (command) {
    case 'register':
      if (!args.length) throw new Error('Pass one or more initialized Operator project roots.');
      for (const root of args) console.log(JSON.stringify(registerProject(resolve(root)), null, 2));
      break;
    case 'projects': console.log(JSON.stringify(listProjects(), null, 2)); break;
    case 'config': {
      // Emit a machine-local connection: no hardcoded developer paths in the package.
      const launch = fileURLToPath(new URL('../launch', import.meta.url));
      console.log(`[mcp_servers.operator_console_v6_alpha]\ncommand = ${JSON.stringify(launch)}\nstartup_timeout_sec = 20\ntool_timeout_sec = 30\n`);
      break;
    }
    case 'serve': {
      if (!args[0]) throw new Error('Usage: node dist/cli.mjs serve /absolute/operator/project [port] [ssh-browser-port]');
      const { serve } = await import('./dev-host.mjs');
      await serve(resolve(args[0]), Number(args[1] || 43132), Number(args[2] || args[1] || 43132));
      break;
    }
    default:
      console.log(`Operator v6-alpha (Node 20+)\n\nregister <project-root> [...]   Add initialized workspaces\nprojects                        List registered projects\nconfig                          Print an absolute-path Codex MCP config\nserve <project-root> [port] [ssh-browser-port]\n                                Open a loopback development host\n\nRegistry: ${registryPath()}\nMCP stdio: run the adjacent launch script without arguments.`);
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
