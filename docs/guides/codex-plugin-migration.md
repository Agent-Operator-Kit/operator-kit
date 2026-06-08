# Codex Plugin Migration

V3 introduces a Codex plugin package for Agent Operator Kit. Existing users may
already have Operator Kit installed as direct skill directories under
`~/.codex/skills`. A safe migration must avoid duplicate Operator surfaces while
preserving any local skill customizations.

The local marketplace used by the migration helper is the development and
release-candidate channel. The final distribution path should be an official or
team marketplace entry, installed with:

```bash
codex plugin add operator-kit@<marketplace>
```

After global plugin install, each project still needs explicit scoped setup with
`operator-sync.sh --skip-skills`.

## Migration Rule

Install the plugin first, then retire legacy direct skill copies.

Do not delete legacy skill directories. Move Operator-owned copies into a
timestamped backup under:

```text
~/.codex/skills/.operator-kit-legacy-backups/<timestamp>/
```

If a legacy skill directory differs from the source bundle, still move it to
the backup by default. That is necessary because a normal V2.1 direct skill copy
will differ from the V3 plugin skill, and leaving it in place would keep the old
skill competing with the plugin. The backup preserves local customizations and
can be restored.

## Command

Preview:

```bash
bash scripts/operator-plugin-migrate.sh --dry-run
```

Migrate:

```bash
bash scripts/operator-plugin-migrate.sh
```

Restore backed-up direct skills:

```bash
bash scripts/operator-plugin-migrate.sh \
  --restore ~/.codex/skills/.operator-kit-legacy-backups/<timestamp>
```

## What The Script Does

`operator-plugin-migrate.sh`:

- copies `plugins/operator-kit` into a durable local marketplace root;
- writes `.agents/plugins/marketplace.json` for that local marketplace;
- runs `codex plugin marketplace add <marketplace-root>`;
- runs `codex plugin add operator-kit@operator-kit-local`;
- compares each bundled legacy skill in `~/.codex/skills/<skill>` against
  `skills/codex/<skill>`;
- moves exact and changed bundled Operator skill directories into the backup;
- leaves unrelated custom skill directories in place.

The default local marketplace root is:

```text
~/.codex/operator-kit-plugin-marketplace
```

The default marketplace name is:

```text
operator-kit-local
```

## Why Changed Skills Are Backed Up

Direct skill directories can contain local edits. The migration backs changed
Operator-owned skill directories up before removing them from the active skill
path. This prevents duplicate skill names while keeping a reversible copy of any
customization.

Use this only if you intentionally want changed legacy Operator skill
directories to keep shadowing or competing with plugin-provided skills:

```bash
bash scripts/operator-plugin-migrate.sh --preserve-changed-legacy
```

## Validation

Run:

```bash
bash tests/smoke/codex-plugin-migration.sh
```

The smoke test uses a fake Codex CLI and temporary `CODEX_HOME`. It verifies
that dry-run writes nothing, plugin marketplace files are created, exact and
changed legacy Operator skills are backed up, unrelated custom skills are
untouched, and backups can be restored.
