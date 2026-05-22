---
name: operator-workflow
description: Use when setting up or operating Agent Operator Kit, tmux lanes, git worktrees, external task packets, handoffs, Cursor background agents, or status summaries.
---

# Operator Workflow

Use this skill to install, maintain, or operate Agent Operator Kit from Cursor.

## Local Cursor Operator Flow

1. Inspect the repo and git status.
2. Read `AGENTS.md`, `operator.config.env`, and `.cursor/rules/operator-workflow.mdc`.
3. Confirm the stable branch and lane map.
4. Install or update Agent Operator Kit scripts/templates if needed.
5. Ensure `OPERATOR_DIR` is outside the repo.
6. Create or verify lane worktrees.
7. Start or inspect tmux.
8. Create a smoke task under `OPERATOR_DIR`.
9. Run:
   - `bash -n scripts/*.sh`
   - `bash scripts/operator-status.sh`
   - `bash scripts/operator-summary.sh`
   - `bash scripts/operator-memory.sh status`
   - `bash scripts/operator-roadmap.sh status`
10. Report installed files, lane map, smoke results, memory/roadmap status, dirty files, and whether the repo is ready to commit.

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

## Cursor Background Agent Flow

Cursor Background Agents run remotely and push a separate branch to GitHub. Do not assume they can access the local `OPERATOR_DIR` or local Operator Memory.

For Background Agent tasks:

1. Put the full task packet in the prompt.
2. Include branch name, scope, read-only areas, validation commands, and handoff requirements.
3. Require a final handoff that names changed files, commands run, tests, blockers, and follow-up needs.
4. Do not use Background Agents for provider-console changes, production deploys, or tasks that require local device/simulator state unless the environment is explicitly configured.
5. Include relevant operator memory explicitly in the prompt when a Background Agent needs it.

## Memory

Use `scripts/operator-memory.sh` for local cross-lane context. Dispatch with
`--with-memory` when a lane needs retrieved context. Promote concise project or
task facts; do not commit generated memory files.

## Roadmap And Feedback

Use `scripts/operator-roadmap.sh` and `scripts/operator-feedback.sh` for local
roadmap, backlog, feedback intake, and screenshot/video annotation workflows.
Keep this state under `OPERATOR_DIR`, not in the app repo.

For Codex Desktop projects, use `$operator-feedback` for intake,
`$operator-planner` for planning, and `$operator` for execution.

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets.
- Do not commit raw handoffs, task packets, pane captures, task working files, or transient notes.
- Do not commit memory packs or generated operator memory.
- Do not start production builds, deployments, or provider-console changes during setup.
- Ask before destructive commands.
- Ask before credential/provider-console changes, release submissions,
  live-money enablement, or product decisions that cannot be safely inferred.
