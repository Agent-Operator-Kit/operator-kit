# V3 Install Flow

V3 splits Operator Kit installation into two explicit layers:

```text
Global host layer
  Codex plugin / Cursor adapter / Claude Code adapter

Project-scoped layer
  operator.config.env / scripts/operator-*.sh / OPERATOR_DIR / lanes / memory / roadmap
```

The global layer makes Operator Kit available in the agent host. The
project-scoped layer remains the operational source of truth for each repo or
folder.

For the agent-chat quickstart, see
`docs/guides/operator-plugin-mode-cheatsheet.md`.

## Distribution Channels

The final user-facing install should use a real marketplace channel:

```bash
codex plugin add operator-kit@<marketplace>
```

For development, release-candidate, and local validation, use a local Codex
marketplace as a stand-in for the final marketplace:

```bash
bash scripts/operator-plugin-migrate.sh --dry-run
bash scripts/operator-plugin-migrate.sh
```

The local marketplace path is intentionally a test/distribution channel, not the
core architecture. It lets us exercise the same Codex plugin install mechanism
before a public or team marketplace entry exists.

## Legacy Codex Skill Migration

Existing users may have direct Operator Kit skills under `~/.codex/skills` from
`codex-skills-install.sh`. V3 migration must prevent those direct skills from
shadowing plugin-provided skills.

The migration helper installs the plugin first, then backs up and retires
bundled legacy Operator skill directories:

```text
~/.codex/skills/.operator-kit-legacy-backups/<timestamp>/
```

Unrelated custom skills stay in place. Backups can be restored with:

```bash
bash scripts/operator-plugin-migrate.sh --restore <backup-dir>
```

## Scoped Project Setup

After the global plugin is installed, project setup should skip legacy global
skill installation and only install project-local Operator Kit files:

```bash
bash scripts/operator-sync.sh \
  --target /path/to/project-root \
  --bootstrap-if-missing \
  --skip-skills
```

For an empty project root, the expected layout is:

```text
project-root/
  code/
    app/
      operator.config.env
      AGENTS.md
      CODEX.md
      CLAUDE.md
      .claude/
      .cursor/
      scripts/operator-*.sh
  operator/
    README.md
    system-map.md
    catalog/
    roadmap/
    memory/
    tasks/
    captures/
```

For an existing repo:

```bash
bash scripts/operator-sync.sh \
  --target /path/to/repo \
  --bootstrap-if-missing \
  --skip-skills
```

For Cursor-first scoped setup:

```bash
bash scripts/operator-sync.sh \
  --target /path/to/project-root \
  --bootstrap-if-missing \
  --bootstrap-profile cursor \
  --skip-skills
```

## Validation

Run the end-to-end V3 install flow smoke:

```bash
bash tests/smoke/v3-final-install-flow.sh
```

The smoke test uses a fake Codex CLI and temporary `CODEX_HOME`. It validates
the local marketplace/plugin migration path, retirement of legacy direct skills,
and a scoped project bootstrap that creates the expected `code/app` plus sibling
`operator` layout without mutating the real user Codex install.
