# Existing Project Setup

1. Clone or update this kit.
2. Run the sync script against your repo.
3. Let it refresh bundled Codex Desktop skills.
4. Let it detect whether the target repo already has Operator Kit.
5. Let it update the installed project and run checks.

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git /path/to/operator-kit
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo
```

From inside an older Operator Kit project, you can use the remote entry point as the single command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
```

If the repo has never had Operator Kit installed, bootstrap intentionally:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing
```

For Cursor-first environments without Codex, use the Cursor bootstrap profile
and skip global Codex skill installation:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

This keeps Cursor IDE as the operator lane, adds a Cursor CLI worker lane, and
keeps Claude Code as an optional UI lane when available.

## Codex Desktop Operation

After installation, Codex Desktop can use the bundled global skills:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --skip-project
```

Then reopen Codex Desktop and run:

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
