# V3 Host Adapter Packaging

This guide defines the V3 global adapter package story for Agent Operator Kit
across Codex, Cursor, and Claude Code.

## Release Boundary

V2 remains the hardening candidate:

- reliability hardening;
- source hygiene and independence cleanup;
- scoped root setup improvements;
- no plugin package integration into `main`.

V3 is the adapter packaging track:

- Codex plugin package;
- Cursor host adapter package;
- Claude Code host adapter package;
- global-install plus explicit project-scoped setup flow;
- version and compatibility reporting across global adapters and
  project-local Operator Kit scripts.

## Package Structure

```text
plugins/operator-kit/
  .codex-plugin/plugin.json
  marketplace-entry.json
  v3-adapter-bundle.json
  skills/                        # Codex plugin skill bundle
  adapters/
    cursor/
      adapter.json
      skills/
      project-templates/.cursor/
      prompts/
    claude-code/
      adapter.json
      skills/
      project-templates/.claude/
```

Codex is a true Codex plugin package. Cursor and Claude Code are host adapter
packages because this repo should not invent unsupported runtime APIs for those
hosts.

## Global Install Versus Project Setup

Global adapter install makes host-specific Operator Kit affordances available:

- Codex: plugin manifest plus direct `skills/<skill>/SKILL.md` bundle;
- Cursor: personal skills under `~/.cursor/skills`, environment hints, and setup
  prompts;
- Claude Code: workflow skill docs, slash commands, and project subagent
  templates.

Global adapters do not replace project-local state and must not bootstrap a
project by themselves.

Project setup remains explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing
```

Cursor-first setup remains explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

Refreshing an installed project remains explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project
```

Global-only refresh remains separate:

```bash
bash scripts/operator-sync.sh --channel latest --skip-project
```

## Sticky Operator Mode

V3 adapters share one sticky-mode contract across Codex, Cursor, and Claude
Code:

- sticky mode changes routing, not execution authority;
- exactly one Operator config or external cockpit profile must be bound;
- `operator observe` is the safest default for initialized sessions;
- feedback requests route to feedback intake, planning requests route to
  planning, and execution requests remain gated by Operator preflight;
- dispatch, collect, merge, push, tag, release, destructive cleanup, provider
  changes, and credential changes require explicit user intent and review.

Codex can expose this as plugin activation and visible mode state when the host
supports it. Cursor and Claude Code should expose the same behavior through
adapter rules, skills, prompts, slash commands, subagents, or docs unless their
hosts provide durable session state.

The durable concept page is `docs/concepts/sticky-operator-mode.md`.

## Project-Local State

These remain project-local or external-cockpit-local:

- `operator.config.env`;
- `scripts/operator-*.sh`;
- `OPERATOR_DIR`;
- lane worktrees and branch map;
- tmux session names;
- task packets, handoffs, captures, working files;
- memory, roadmap, feedback inbox, system map, and catalog.

No adapter package should require `operator.config.env` at the source repo root.
Adapters should only expect it in a target project after explicit setup.

## Version And Compatibility

V3 adapter bundle version starts at `0.1.0` in
`plugins/operator-kit/v3-adapter-bundle.json`.

Each adapter package has matching `version` and `bundleVersion` fields:

- Codex plugin: `plugins/operator-kit/.codex-plugin/plugin.json`;
- Cursor adapter: `plugins/operator-kit/adapters/cursor/adapter.json`;
- Claude Code adapter:
  `plugins/operator-kit/adapters/claude-code/adapter.json`.

V3 adapter bundle `0.1.0` targets project-local `OPERATOR_KIT_VERSION="2"`.
Future status or diagnostics tooling should report both:

- global adapter package version;
- project-local Operator Kit script/template version.

Compatibility policy:

- adapter patch/minor releases may update docs, packaging metadata, and
  non-breaking host affordances for Operator Kit V2 projects;
- breaking changes to project-local scripts/templates require a future
  `OPERATOR_KIT_VERSION` bump or an adapter major version with migration docs;
- adapters must keep wrapping or pointing users to project-local scripts rather
  than bypassing them.

## Host-Specific Limits

Codex:

- true plugin package;
- direct skills live under `plugins/operator-kit/skills/`;
- future MCP/tools may wrap status, dispatch, collect, or upgrade, but should
  call project-local scripts.

Cursor:

- adapter package only;
- global install writes personal skills under `~/.cursor/skills`;
- rules and project-specific skills remain explicit Cursor project assets;
- Cursor Cloud Agents are remote branch workers and cannot assume local tmux,
  simulators, `OPERATOR_DIR`, or local memory;
- include task packets and relevant memory directly in Cursor Cloud Agent
  prompts.

Claude Code:

- adapter package only;
- slash commands and subagents are explicit project assets under `.claude/`;
- no hidden Claude runtime plugin API is assumed;
- Claude Code lanes use the same task packet, handoff, memory, and roadmap
  model as other lanes.

## Validation

Run:

```bash
bash tests/smoke/v3-host-adapters.sh
```

The smoke test validates package metadata, packaged asset existence, copy sync
against canonical host assets, no user-global validation writes, and no source
repo root `operator.config.env` dependency.
