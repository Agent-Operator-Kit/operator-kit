# Agent Operator Kit Codex Plugin

This directory is the first source scaffold for packaging Agent Operator Kit as
a Codex plugin.

## Package Layout

```text
plugins/operator-kit/
  .codex-plugin/plugin.json
  marketplace-entry.json
  v3-adapter-bundle.json
  adapters/
    cursor/
    claude-code/
  skills/
    operator/
    operator-workflow/
    operator-feedback/
    operator-planner/
    design-agent/
    ux-auditor/
    user-journey/
    incubation/
```

Codex plugin archives discover skills from direct `skills/<skill-name>/`
children. The canonical source skills still live in `skills/codex/`; this
package contains a direct copy in the plugin archive shape. Keep the copy in
sync with:

```bash
rsync -a --delete --exclude='.DS_Store' skills/codex/ plugins/operator-kit/skills/
bash tests/smoke/codex-plugin-package.sh
```

## Boundary

The global Codex plugin owns:

- marketplace entry metadata for `operator-kit`
- `.codex-plugin/plugin.json`
- the installable Codex skill bundle
- plugin-facing install/update documentation
- future Codex MCP/tools for status, dispatch, collect, upgrade, or diagnostics

The V3 adapter bundle adds host packages for Cursor and Claude Code under
`adapters/`. Those packages are metadata and asset bundles, not hidden runtime
APIs.

The project-local layer owns:

- `operator.config.env`
- `scripts/operator-*.sh`
- `OPERATOR_DIR`
- lane worktrees, tmux session names, task packets, handoffs, roadmap, memory,
  captures, and project catalog files

The marketplace entry template points at `./plugins/operator-kit`. A live
marketplace file belongs to the distribution channel that installs this package.
Installing this plugin must not create or mutate project-local state. Project
setup and sync stay explicit through `operator-sync.sh`, `operator-upgrade.sh`,
or project-local `scripts/operator-*.sh`.

After this plugin owns global Codex skills, scoped project setup should skip
legacy direct skill installation:

```bash
bash scripts/operator-sync.sh --target /path/to/project-root --bootstrap-if-missing --skip-skills
```

## Legacy Skill Migration

Users who previously installed Operator Kit through `codex-skills-install.sh`
may have direct skill directories under `~/.codex/skills`. During V3 migration,
install the plugin first and then retire Operator-owned direct skill copies:

```bash
bash scripts/operator-plugin-migrate.sh --dry-run
bash scripts/operator-plugin-migrate.sh
```

The migration backs up retired skills under
`~/.codex/skills/.operator-kit-legacy-backups/<timestamp>/`. Changed
Operator-owned direct skill directories are backed up too, so older V2 direct
skills do not keep competing with the V3 plugin while local customizations stay
recoverable.

## Sticky Operator Mode

The V3 package advertises sticky Operator mode as a shared host contract:
default routing without automatic execution. Use `operator observe` as the safe
default for initialized chats, `operator active` for feedback/planning/task
creation, and `operator dispatch` only when the user clearly asks to execute and
preflight passes.

Sticky mode does not permit implicit dispatch, collect, merge, push, tag,
release, destructive cleanup, provider changes, or credential changes. The full
contract lives in `docs/concepts/sticky-operator-mode.md`.

## Version Compatibility

`plugin.json` uses semver for the global Codex adapter package. Slice 1 starts
at `0.1.0` and targets project-local `OPERATOR_KIT_VERSION="2"`.

Compatibility rule:

- plugin patch/minor releases may add skills, docs, or non-breaking tool
  affordances for Operator Kit V2 projects;
- plugin major releases or a future `OPERATOR_KIT_VERSION` bump are required
  for project-local breaking changes;
- setup/sync UX should report both versions once structured tooling exists:
  global plugin version and project-local kit version.

Cursor and Claude adapters remain separate follow-on milestones. They should
consume the same Operator Kit project-local substrate, not fork the execution
model inside this Codex plugin package.
