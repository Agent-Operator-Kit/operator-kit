# Existing Project Setup

1. Clone this kit.
2. Run the bootstrap script against your repo.
3. Edit `operator.config.env`.
4. Start tmux.
5. Create a smoke task.
6. Dispatch to a worker lane.
7. Collect a handoff.
8. Confirm generated state lands under `OPERATOR_DIR`, not the repo.

```bash
bash scripts/operator-bootstrap.sh /path/to/repo
cd /path/to/repo
bash scripts/operator-tmux.sh start
bash scripts/operator-task.sh smoke-001 "Smoke task"
bash scripts/operator-status.sh
```

## Codex Desktop Operation

After installation, Codex Desktop can use the bundled global skills:

```bash
bash /path/to/operator-kit/scripts/codex-skills-install.sh
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

```text
Use $operator. Update to latest version from git.
```

This runs the safe update flow: refresh evergreen scripts, install missing templates, keep `operator.config.env` and existing project docs/assets, then report what changed.
