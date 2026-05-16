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
5. Use `scripts/operator-task.sh`, `scripts/operator-dispatch.sh`, `scripts/operator-collect.sh`, `scripts/operator-summary.sh`, and `scripts/operator-memory.sh`.
6. Commit only evergreen repo changes.

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

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

Do not assume Background Agents can access local Operator Memory. Include the
relevant context explicitly in the prompt or task packet.

## Memory

Local Cursor operator work can use `operator-dispatch.sh --with-memory` to add
a compact context pack. Use project memory for durable facts and task memory for
feature-track facts. Do not commit generated memory files.

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets.
- Do not commit raw handoffs, task packets, pane captures, or transient notes.
- Do not commit memory packs or generated operator memory.
- Do not start deployments or production builds during setup.
- Ask before destructive cleanup, credential/provider-console changes,
  production deploys, release submissions, live-money enablement, or product
  decisions that cannot be safely inferred.
