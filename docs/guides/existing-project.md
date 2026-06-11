# Existing Project Setup

1. Clone or update this kit.
2. Run the sync script against your repo.
3. Let it refresh bundled global host skills.
4. Let it detect whether the target repo already has Operator Kit.
5. Let it update the installed project and run checks.

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git /path/to/operator-kit
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo
```

Stable remains V2.1; `--channel latest` installs V5 for fresh projects. After sync, inspect the project-specific role and lane
recommendations:

```bash
cd /path/to/repo
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-catalog.sh list roles
```

From inside an older Operator Kit project, you can use the remote entry point as the single command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
```

If the repo has never had Operator Kit installed, bootstrap intentionally:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing
```

For Cursor-first environments, use the Cursor bootstrap profile and skip global
host skill installation when personal skills are already installed:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

This keeps Cursor IDE as the operator lane, adds a Cursor CLI worker lane, and
keeps Claude Code as an optional UI lane when available.

## Global Host Skills

After installation, Codex Desktop and Cursor can use the bundled global skills:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --channel latest --skip-project
```

Then reopen Codex Desktop or reload Cursor and run:

```text
Use $operator. Show project status.
Use $operator. Summarize blockers across all lanes.
Use $operator. Collect backend result for smoke-001 and tell me if it is ready to integrate.
Use $design-agent. Do a comprehensive UX and consistency review.
```

The skill detects installed, partial, and missing Operator Kit states before it operates. It should not dispatch or collect work in a partial install.

To refresh an existing project from the latest kit source while preserving project-specific files:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo
```

This runs the safe update flow: refresh evergreen scripts, install missing templates, keep `operator.config.env` and existing project docs/assets, then report what changed.

For an existing V4 project, that update intentionally preserves
`OPERATOR_KIT_VERSION="4"` and reports `migration required`. Review the
lossless inventory before any marker change:

```bash
bash scripts/operator-v5-migrate.sh plan > /secure/review/v5-plan.json
```

Follow [Operator Kit V4-to-V5 migration](operator-v5-migration.md). Migration
requires stopped writers, an external private `OPERATOR_DIR`, available
broker/keychain tooling, a reviewed mapping, explicit authorization, and no
incompatible graph state. It preserves all V4 artifacts and does not infer or
write graph truth from them.
