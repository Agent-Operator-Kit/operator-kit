# Cursor Operator Workflow Skill

Use this skill when setting up or operating Agent Operator Kit from Cursor IDE, Cursor CLI, or Cursor Background Agents.

Cursor integration has three layers:

- `.cursor/rules/operator-workflow.mdc` for persistent project guidance.
- `.cursor/skills/operator-workflow/SKILL.md` for procedural setup and operations.
- `.cursor/environment.json.example` as a starting point for Background Agent environments.

## Local Cursor Operator

Use Cursor IDE Agent or Cursor CLI when Cursor should operate the local worktrees and tmux lanes.

The local flow:

1. Inspect the repo and git status.
2. Read `operator.config.env`.
3. Confirm lane map and expected branches.
4. Keep generated state under `OPERATOR_DIR`.
5. Use `scripts/operator-task.sh`, `scripts/operator-dispatch.sh`, `scripts/operator-collect.sh`, and `scripts/operator-summary.sh`.
6. Commit only evergreen repo changes.

## Cursor CLI

Cursor CLI uses `cursor-agent`.

Useful commands:

```bash
cursor-agent
cursor-agent "Set up Agent Operator Kit for this repo"
cursor-agent -p "Review this branch for operator workflow regressions" --output-format text
```

Use non-interactive mode carefully because it can have write access depending on flags and configuration.

## Cursor Background Agents

Background Agents run remotely, clone from GitHub, work on a separate branch, and push back to the repo.

Use them for isolated branch work. Do not assume access to local tmux sessions, local simulators, or local `OPERATOR_DIR`.

For every Background Agent prompt, include:

- branch name
- task scope
- read-only areas
- validation commands
- handoff requirements

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets.
- Do not commit raw handoffs, task packets, pane captures, or transient notes.
- Do not start deployments or production builds during setup.
