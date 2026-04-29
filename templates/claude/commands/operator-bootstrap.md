---
description: Set up Agent Operator Kit for a target repo
argument-hint: [absolute-path-to-repo]
---

Set up Agent Operator Kit for this project.

Target repo:

```text
$ARGUMENTS
```

Source kit:

```text
git@github.com:Agent-Operator-Kit/operator-kit.git
```

Follow the agent-run bootstrap flow:

1. Inspect the target repo first.
2. Identify default branch, remotes, package manager, validation commands, and current docs.
3. Propose a lane map before creating worktrees.
4. Install the kit scripts/templates.
5. Ensure `operator.config.env` matches the project.
6. Ensure the external operator workspace is outside the repo.
7. Create or verify lane worktrees without overwriting existing work.
8. Start tmux if available.
9. Create a smoke task under `OPERATOR_DIR`.
10. Run:
    - `bash -n scripts/*.sh`
    - `bash scripts/operator-status.sh`
    - `bash scripts/operator-summary.sh`
11. Report installed files, `OPERATOR_DIR`, lane map, smoke results, git status, and whether the repo is ready to commit.

Do not commit raw handoffs, task packets, pane captures, or transient notes. Do not rewrite git history, force-push, deploy, or run production builds.
