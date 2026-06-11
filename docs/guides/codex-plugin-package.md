# Codex Plugin Packaging Plan

This guide captures the RM-0001 slice-1 packaging boundary for Agent Operator
Kit as a Codex plugin.

## Goal

Install Agent Operator Kit once globally in Codex, then require explicit setup
or sync for each project that should use Operator Kit.

The plugin improves discovery and update coherence. It does not replace the
project-local execution substrate.

## Source Layout

```text
plugins/operator-kit/
  .codex-plugin/plugin.json      # Codex plugin manifest
  marketplace-entry.json         # marketplace entry template
  v3-adapter-bundle.json         # multi-host V3 adapter bundle metadata
  README.md                      # package boundary and compatibility notes
  skills/                        # direct plugin skill bundle
  adapters/                      # Cursor and Claude Code host adapters

skills/codex/                    # canonical Codex skill source
scripts/codex-skills-install.sh  # legacy direct skill installer
scripts/operator-sync.sh         # explicit project setup/sync entry point
scripts/operator-upgrade.sh      # global refresh plus project sync orchestration
```

Codex plugin ingestion discovers skills at direct `skills/<skill>/` children.
The repository keeps host-specific source skills under `skills/codex/`,
`skills/cursor/`, and `skills/claude-code/`; the plugin package therefore keeps
a direct copy of `skills/codex/` in `plugins/operator-kit/skills/`.

`tests/smoke/codex-plugin-package.sh` validates that this package copy remains
in sync with the canonical Codex skill source.

## Global Versus Project-Local

Global Codex plugin responsibilities:

- publish marketplace entry metadata that points at `./plugins/operator-kit`;
- publish `.codex-plugin/plugin.json`;
- bundle Codex skills for `operator`, `operator-workflow`,
  `operator-feedback`, `operator-planner`, `design-agent`, `ux-auditor`,
  `user-journey`, and `incubation`;
- document global install/update behavior;
- later expose structured Codex tools only when they wrap project-local scripts
  instead of bypassing them.

Project-local responsibilities:

- `operator.config.env`;
- `scripts/operator-*.sh`;
- `OPERATOR_DIR`;
- lane maps, git worktrees, tmux sessions, task packets, handoffs, memory,
  roadmap, captures, and catalog files.

Installing the global plugin must not bootstrap a project. Project setup stays
an explicit action:

```bash
bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing
```

Refreshing an installed project stays explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project
```

Global-only refresh stays separate:

```bash
bash scripts/operator-sync.sh --skip-project
```

For V3 plugin installs, project setup should normally skip the legacy direct
Codex skill installer because the plugin owns global skills:

```bash
bash scripts/operator-sync.sh --target /path/to/project-root --bootstrap-if-missing --skip-skills
```

See [V3 install flow](v3-install-flow.md) for the complete global-plus-scoped
contract.

## Legacy Skill Migration

Existing users may already have Operator Kit installed as direct skill
directories under `~/.codex/skills`. V3 plugin installation should not leave
those direct copies competing with plugin-provided skills, but it also must not
silently remove user customizations.

Use the migration helper:

```bash
bash scripts/operator-plugin-migrate.sh --dry-run
bash scripts/operator-plugin-migrate.sh
```

The helper installs the plugin first, then moves legacy Operator-owned
skill copies into `~/.codex/skills/.operator-kit-legacy-backups/<timestamp>/`.
Changed legacy Operator skill directories are backed up too, because V2.1 direct
skills naturally differ from V3 plugin skills. Unrelated custom skills are left
in place.

See [Codex plugin migration](codex-plugin-migration.md).

## Sticky Activation

The Codex plugin can make Operator easier to invoke, but sticky mode is still a
routing contract rather than an execution grant. After a user initializes
Operator for a chat/project, the supported mode vocabulary is:

```text
operator off
operator observe
operator active
operator dispatch
```

`operator observe` should be the safe default. It allows natural phrases such as
`status`, `what is blocked?`, and `summarize lanes` to route through Operator
status, roadmap, memory, and handoff context when exactly one Operator config is
bound. `operator active` can also capture feedback, shape roadmap/planning
items, and create task packets when the user's wording is clear. `operator
dispatch` can run lane execution only after explicit user intent and preflight.

Sticky activation must not silently dispatch, collect, merge, push, tag,
release, delete files, change providers, or mutate credentials. See
`docs/concepts/sticky-operator-mode.md` for the full shared contract.

## Compatibility Strategy

The plugin version and the project-local script/template version are separate
contracts:

- Codex plugin version: `.codex-plugin/plugin.json` semver, starting at
  `0.1.0`.
- Project-local version: `OPERATOR_KIT_VERSION="2"` in `operator.config.env`
  and generated fixtures.

For Operator Kit V2, plugin patch/minor releases may update skills, docs, or
non-breaking tool affordances. Breaking project-local changes require a future
project kit version bump or plugin major version with clear migration docs.

Future structured tools should surface both versions in status/diagnostics so
users can tell whether the global adapter and project-local substrate are
compatible.

## Follow-On Adapter Milestones

Cursor adapter:

- keep `.cursor/rules`, `.cursor/skills`, environment hints, bootstrap prompts,
  and Cursor-first lane profiles outside the Codex plugin package;
- continue using project-local `operator.config.env`, scripts, task packets,
  handoffs, memory, and roadmap.

Claude adapter:

- keep `.claude/commands`, `.claude/agents`, and Claude Code workflow docs
  outside the Codex plugin package;
- continue using the same project-local execution substrate.

Neither adapter should fork Operator Kit state or dispatch semantics.

## Marketplace Metadata

`plugins/operator-kit/marketplace-entry.json` contains the source entry shape
for a Codex marketplace:

```json
{
  "name": "operator",
  "source": {
    "source": "local",
    "path": "./plugins/operator-kit"
  },
  "policy": {
    "installation": "AVAILABLE",
    "authentication": "ON_INSTALL"
  },
  "category": "Developer Tools"
}
```

The live marketplace file location belongs to the distribution channel. This
source repo currently keeps the entry as package metadata instead of installing
or mutating a personal marketplace.

## Validation

Plugin-specific smoke:

```bash
bash tests/smoke/codex-plugin-package.sh
bash tests/smoke/v3-host-adapters.sh
```

General source validation:

```bash
bash -n scripts/*.sh tests/smoke/*.sh
git diff --check
bash tests/smoke/bootstrap-existing-project.sh
```
