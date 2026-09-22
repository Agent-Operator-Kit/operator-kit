# Operator v6-alpha

A local MCP Apps cockpit with a registered-project sidebar, automatic refresh,
English/Polish UI and host-aware light/dark appearance. Package version:
`0.6.0-alpha.1`. This V6 cockpit alpha does **not** migrate project runtime markers
or replace existing V5.1/V5.2 graph workflows.

## Pull and run elsewhere

Prerequisites: Node 20+ and initialized Operator workspaces. Python 3 provides the
workspace's canonical graph frontier; tmux is optional. The root passed below must
contain `operator.config.env` and reference local Operator records. Pulling this
repository does not copy private project records.

```sh
git clone --branch codex/operator-v6-alpha https://github.com/Agent-Operator-Kit/operator-kit.git
cd operator-kit/plugins/operator-kit/mcp-server
node dist/cli.mjs register /absolute/path/to/project-a /absolute/path/to/project-b
node dist/cli.mjs serve /absolute/path/to/project-a
```

Open `http://127.0.0.1:43132`. Click **All projects**, then use **Language** and
**Appearance**. The preview's top bar simulates host language/theme changes and
connection failure. It uses the real stdio server; Codex navigation is available
only through an appropriate native host adapter.

`dist/` is committed and self-contained: no `npm install` is needed to run it.
Existing checkouts can fetch and switch to `codex/operator-v6-alpha` or the immutable
`operator-v6-alpha.1` tag, preserving local edits.

### Native Codex

```sh
node dist/cli.mjs config
```

Add the printed TOML block once to the intended project's `.codex/config.toml`,
or to user config for availability across projects. Preserve existing settings
and avoid duplicate connections. Reload MCP connections or restart Codex, then ask:

> Open the Operator console for /absolute/path/to/initialized/project.

The generated command uses **this machine's** absolute launcher path. `launch`
resolves its bundled server relative to itself and works from any directory,
including paths with spaces. It also accepts an explicit server path for older
connections. Set `CODEX_MCP_NODE_PATH` if Node is absent from the desktop PATH.

The legacy plugin manifest remains included for skills/package distribution.
Its relative MCP command is not validated across Codex versions: the generated
absolute-path connection is the supported alpha setup. Installing a plugin alone
does not prove its MCP server launched. A running POC server must be reloaded for
new tools; reopen existing cards to load the new resource URI.

For another MCP Apps host, configure a local stdio command pointing to `launch`.
On Windows or hosts requiring an executable, run `node` with an absolute
`dist/server.mjs` argument. UI rendering/modes/navigation remain host-dependent.

## Project registry and persistence

- Register through the CLI or **All projects → Add project**. Registration validates
  the supplied root without executing its shell configuration.
- The current project is always included. Other projects require registration;
  there is no full-disk scan or direct access to Codex's internal project database.
- Registry and language/theme/sidebar preferences live at
  `${XDG_CONFIG_HOME:-~/.config}/operator/console/projects.json`. Override the file
  using `OPERATOR_CONSOLE_REGISTRY` for isolated tests. Back up the file before
  manually removing or relocating a registration.
- Worktrees sharing a canonical `OPERATOR_DIR` appear once. Independent Operator
  directories stay separate even when they share a Git remote.
- Sidebar counts use lightweight local record reads, without executing every
  project's graph frontier. Missing/malformed projects show unavailable; healthy
  projects remain usable. Failed list refreshes retain previous rows with a warning.
- Explicit switches fetch full snapshots. Ordinary polls enforce project identity.
  Selection, tab and scroll restore per project.
- View preferences live in `OPERATOR_DIR/console/views/`, keyed by local home
  directory hash. This is local presentation state, not authenticated team state.
  Preferences are excluded from business-data revisions.
- `OPERATOR_PROJECT_ID` can provide a configured identity. The fallback hashes
  the canonical project root and changes when a project moves.

The registry is an index, not a filesystem authorization boundary. The server has
the launching user's local access. Remote service hosting needs authentication,
authorization, transport and data-adapter work; do not expose this alpha publicly.

## Language and theme

Language priority: explicit choice → host locale → browser locale → English.
English and Polish catalogs are bundled; unsupported locales use English. Dates
and numbers follow UI locale; a supplied host timezone is honored. Project titles
and documents retain their original language. Raw runtime diagnostics stay as
source text.

Appearance priority: explicit light/dark → host theme → system preference. Follow
host uses host style variables. Explicit overrides use local palettes so light
still works when the host provides dark colors. Host context updates apply live.
Preferences persist across remounts; another already-open console retains its
current choices until reopened.

## Packaging and hosting

```text
Codex MCP connection → launch → local Node stdio server
                                  ├─ Operator files + canonical Python runtime
                                  ├─ local project registry/preferences
                                  └─ bundled HTML → host sandbox → MCP tool calls
```

| Artifact | Purpose |
|---|---|
| `dist/server.mjs` | MCP SDK, tools, local data adapters |
| `dist/console.html` | Embedded UI, SDK, CSS and translations |
| `dist/cli.mjs` | Project registration and machine-local config |
| `dist/dev-host.mjs`, `dist/host.js` | Optional browser development host |
| `launch` | Local Node discovery and stdio startup |

No cloud backend, public port, external CDN or translation service is needed for
native use. The optional browser host binds to `127.0.0.1`, validates Host/Origin
and uses a per-process request token. Project registrations and user records are
not shipped in this repository.

## Build and verify

### Open the web preview from another computer over SSH

The default `/` page renders the cockpit directly in the document for element
inspection and design annotations. It builds from the same `src/ui.js` and CSS
as the native MCP resource, with an in-memory SDK App/AppBridge connection to the
existing HTTP-to-MCP development host. `/embedded` retains the iframe host and
its theme/language/disconnection controls for MCP integration testing. Native
MCP rendering continues to use `dist/console.html`; the direct browser page is
`dist/web.html`. Browser task navigation still requires the Codex host and is
not available in either web preview mode.

Start the preview on the project host, explicitly allowing the laptop's local
forwarded port as the optional final argument:

```sh
node dist/cli.mjs serve /absolute/operator/project 43132 43133
```

In a terminal **on the laptop**, keep this authenticated SSH tunnel running:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:43133:127.0.0.1:43132 user@project-host
```

Open `http://127.0.0.1:43133/` in the laptop's browser. The host remains bound to
loopback. Only the listening port and the explicit forwarded browser port are
accepted, and each RPC request's Origin must match its Host. A different local
port without the corresponding server argument produces HTTP 403. SSH access
and a reachable project host are prerequisites; Codex Remote alone does not set
up this tunnel. Restarting the preview changes its request token, so reload any
already-open preview tabs.

### Rebuild the package

```sh
npm ci
npm run build
npm test
```

Commit updated `dist/` after source changes. Protocol tests cover readiness,
revision polling, project isolation, view persistence, registry deduplication and
failure isolation, language fallback, and relocation without `node_modules`.
Browser checks cover A→B→A restoration, external updates, stale/recovery, remount,
theme changes, explicit overrides, Polish labels and narrow/expanded layouts.

## Tools and limits

- `operator_console`: full snapshot and `ui://operator/console-v6-alpha.html`.
- `operator_console_refresh`: bound-project polling without opening another card.
- `operator_console_save_view`: app-only per-project view persistence.
- `operator_console_projects`: app-only registry overview.
- `operator_console_register_project`: app-only explicit registration.
- `operator_console_preferences`: app-only language, theme and sidebar settings.

No tool dispatches work or changes feature/task records. Readiness uses the
project's `scripts/operator_local_graph.py frontier`; failures produce unavailable
eligibility. A tmux window indicates window presence, not worker activity.

Polling runs every four seconds while visible, refreshes on return, prevents
overlapping project reads, backs off on errors and preserves stale data with a
label. Reads remain synchronous/local; large portfolios need bounded async reads
and caching before scaling.

**Expand / Back to inline** requests MCP display modes. The host decides size.
Codex's workspace fullscreen toolbar is a separate host action. Persistent display
across task switches and detached windows remain unverified. **Open Codex task**
requests navigation through the conversation and never dispatches work.

### Accepted design system

The live console uses the shared `design-system/tokens.json` and `tokens.dark.json` in both native and browser builds. Inter Variable is embedded with the HTML; its license is in the design-system directory. No font CDN is required. Host appearance remains the automatic theme source; manual light/dark selection is supported. The project sidebar collapses into an icon rail and preserves its state through polls and renders. `/preview.html` aliases the live browser page for existing SSH preview links.
