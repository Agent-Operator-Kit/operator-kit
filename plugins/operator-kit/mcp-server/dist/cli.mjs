#!/usr/bin/env node
import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);

// src/cli.mjs
import { fileURLToPath } from "node:url";
import { resolve as resolve2 } from "node:path";

// src/projects.mjs
import { existsSync as existsSync2, readFileSync as readFileSync2, readdirSync as readdirSync2, mkdirSync as mkdirSync2, writeFileSync as writeFileSync2, renameSync as renameSync2, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join as join2 } from "node:path";
import { randomUUID } from "node:crypto";

// src/state.mjs
import { existsSync, readFileSync, readdirSync, realpathSync, mkdirSync, writeFileSync, renameSync } from "node:fs";
import { basename, isAbsolute, join, resolve } from "node:path";
import { createHash } from "node:crypto";
var hash = (value) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
function literal(raw, key) {
  const line = raw.split("\n").find((line2) => line2.startsWith(`${key}=`));
  if (!line) return "";
  const value = line.slice(key.length + 1).trim();
  const match = value.match(/^(?:"([^"\n]*)"|'([^'\n]*)'|([^\s#]+))\s*(?:#.*)?$/);
  if (!match) throw new Error(`Unsupported config value: ${key}. Use a literal path or value.`);
  const result = match[1] ?? match[2] ?? match[3];
  if (/[$`]/.test(result)) throw new Error(`Config expansion is not supported for ${key}.`);
  return result;
}
function config(root) {
  const raw = readFileSync(join(root, "operator.config.env"), "utf8");
  const block = raw.match(/^OPERATOR_LANES='\r?\n([\s\S]*?)\r?\n'/m)?.[1] || "";
  return {
    name: literal(raw, "PROJECT_NAME") || basename(root),
    id: literal(raw, "OPERATOR_PROJECT_ID"),
    operatorDir: resolve(root, literal(raw, "OPERATOR_DIR") || "operator"),
    kitVersion: literal(raw, "OPERATOR_KIT_VERSION") || "unknown",
    session: literal(raw, "TMUX_SESSION"),
    lanes: block.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
      const [id, owner, worktree, branch] = line.split("|");
      return { id, owner, worktree, branch };
    })
  };
}
function projectInfo(projectRoot) {
  if (!projectRoot || !isAbsolute(projectRoot)) throw new Error("Pass the absolute initialized projectRoot. This console never falls back to another project.");
  if (!existsSync(join(projectRoot, "operator.config.env"))) throw new Error("No operator.config.env at the requested projectRoot. Select an initialized Operator project.");
  const root = realpathSync(projectRoot);
  const cfg = config(root);
  const operatorDir = realpathSync(cfg.operatorDir);
  const project = { id: cfg.id || `local-${hash(root).slice(0, 20)}`, root, operatorDir, name: cfg.name, kitVersion: cfg.kitVersion, identityScope: cfg.id ? "configured" : "local-path" };
  return project;
}

// src/projects.mjs
var defaults = { language: "auto", appearance: "auto", allProjects: false };
var registryPath = () => process.env.OPERATOR_CONSOLE_REGISTRY || join2(process.env.XDG_CONFIG_HOME || join2(homedir(), ".config"), "operator", "console", "projects.json");
function registry() {
  const path = registryPath();
  if (!existsSync2(path)) return { version: 1, roots: [], preferences: defaults };
  const value = JSON.parse(readFileSync2(path, "utf8"));
  if (value.version !== 1 || !Array.isArray(value.roots) || !value.roots.every((r) => typeof r === "string")) throw new Error("Invalid Operator console registry. Repair projects.json before adding projects.");
  return value;
}
function update(change) {
  const path = registryPath(), lock = `${path}.lock`, temporary = `${path}.${randomUUID()}.tmp`;
  mkdirSync2(dirname(path), { recursive: true });
  try {
    mkdirSync2(lock);
  } catch {
    throw new Error("Project settings are being saved by another console. Retry shortly.");
  }
  try {
    const next = change(registry());
    writeFileSync2(temporary, JSON.stringify(next, null, 2) + "\n", { mode: 384 });
    renameSync2(temporary, path);
    return next;
  } finally {
    rmSync(temporary, { force: true });
    rmSync(lock, { recursive: true, force: true });
  }
}
function registerProject(root) {
  const project = projectInfo(root);
  update((data) => {
    const duplicate = data.roots.some((r) => {
      try {
        return projectInfo(r).operatorDir === project.operatorDir;
      } catch {
        return r === project.root;
      }
    });
    return { ...data, roots: duplicate ? data.roots : [...data.roots, project.root] };
  });
  return project;
}
function listProjects(currentRoot) {
  const data = registry(), seen = /* @__PURE__ */ new Set();
  const projects = [...new Set([currentRoot, ...data.roots].filter(Boolean))].flatMap((root) => {
    try {
      const project = projectInfo(root);
      if (seen.has(project.operatorDir)) return [];
      seen.add(project.operatorDir);
      const folder = join2(project.operatorDir, "features");
      let features = 0, attention = 0, active = 0, lastActivity = "";
      for (const entry of existsSync2(folder) ? readdirSync2(folder, { withFileTypes: true }) : []) {
        if (!entry.isDirectory() || !entry.name.startsWith("FS-")) continue;
        const status = JSON.parse(readFileSync2(join2(folder, entry.name, "status.json"), "utf8"));
        if (typeof status.id !== "string" || typeof status.status !== "string") throw new Error("Incomplete feature status");
        features++;
        if (["blocked", "in-review", "human-feedback"].includes(status.status)) attention++;
        lastActivity = [lastActivity, status.updatedAt || status.lastActivity || ""].sort().at(-1);
        const graphPath = join2(folder, entry.name, "graph.json");
        if (existsSync2(graphPath)) {
          const graph = JSON.parse(readFileSync2(graphPath, "utf8"));
          if (!Array.isArray(graph.nodes) || graph.featureId !== status.id) throw new Error("Invalid feature graph");
          active += graph.nodes.filter((n) => n.state === "active").length;
          attention += graph.nodes.filter((n) => ["blocked", "failed"].includes(n.state) || n.approval === "pending").length;
          lastActivity = [lastActivity, graph.updatedAt || ""].sort().at(-1);
        }
      }
      return [{ ...project, available: true, summary: { features, attention, active }, lastActivity }];
    } catch (error) {
      return [{ root, name: root.split("/").at(-1), available: false, error: error.message }];
    }
  });
  return { projects, preferences: { ...defaults, ...data.preferences }, generatedAt: (/* @__PURE__ */ new Date()).toISOString() };
}

// src/cli.mjs
var [command, ...args] = process.argv.slice(2);
try {
  switch (command) {
    case "register":
      if (!args.length) throw new Error("Pass one or more initialized Operator project roots.");
      for (const root of args) console.log(JSON.stringify(registerProject(resolve2(root)), null, 2));
      break;
    case "projects":
      console.log(JSON.stringify(listProjects(), null, 2));
      break;
    case "config": {
      const launch = fileURLToPath(new URL("../launch", import.meta.url));
      console.log(`[mcp_servers.operator_console_v6_alpha]
command = ${JSON.stringify(launch)}
startup_timeout_sec = 20
tool_timeout_sec = 30
`);
      break;
    }
    case "serve": {
      if (!args[0]) throw new Error("Usage: node dist/cli.mjs serve /absolute/operator/project [port] [ssh-browser-port]");
      const { serve } = await import("./dev-host.mjs");
      await serve(resolve2(args[0]), Number(args[1] || 43132), Number(args[2] || args[1] || 43132));
      break;
    }
    default:
      console.log(`Operator v6-alpha (Node 20+)

register <project-root> [...]   Add initialized workspaces
projects                        List registered projects
config                          Print an absolute-path Codex MCP config
serve <project-root> [port] [ssh-browser-port]
                                Open a loopback development host

Registry: ${registryPath()}
MCP stdio: run the adjacent launch script without arguments.`);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
