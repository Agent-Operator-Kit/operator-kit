---
name: operator-workflow
description: "Use for Agent Operator Kit setup, bootstrap, repair, and feature-track workflow guidance in Codex. Use when installing Operator Kit into a project, repairing a partial install, creating external operator workspaces, setting up tmux lanes and git worktrees, or validating smoke-task handoffs."
---

# Operator Workflow Skill

Use this skill when a user asks Codex to set up or repair an Agent Operator Kit installation using git worktrees, tmux, external task packets, and operator-owned integration.

For day-to-day operation inside an already installed project, prefer the runtime `$operator` skill in `skills/codex/operator/SKILL.md`.

## Workflow

1. Inspect the project root and git status.
2. Identify default branch, package manager, and validation commands.
3. Propose or read a lane map.
4. Create an external operator workspace.
5. Install or update operator scripts, Operator Memory Router, and evergreen docs.
6. Install Claude Code project assets under `.claude/` when the target project uses Claude Code.
7. Install Cursor project assets under `.cursor/` when the target project uses Cursor.
8. Create lane worktrees and branches.
9. Start tmux lanes.
10. Create a smoke task under the external operator workspace.
11. Verify `scripts/operator-memory.sh status`.
12. Dispatch and collect one smoke handoff when appropriate.
13. Report exact paths, branches, commands, memory status, and validation status.

## Agent-Run Setup

When the user wants an agent to fully set up the system from scratch, follow `docs/guides/agent-run-bootstrap.md` and the prompt template in `templates/prompts/agent-run-bootstrap.md`.

The setup agent should inspect first, propose a lane map, install scripts/templates, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

## Memory

Installed projects should include `scripts/operator-memory.sh` and
`OPERATOR_DIR/memory/`. Use task memory for feature-track facts, project memory
for durable cross-task facts, and `operator-dispatch.sh --with-memory` only
when retrieved context is relevant to the target lane.

## Operating Feature Tracks

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

Pause for user input before destructive cleanup, credential changes,
provider-console changes, production deploys, release submissions,
live-money/trading enablement, or product decisions that cannot be safely
inferred.

## Guardrails

- Do not commit raw handoffs, pane captures, task packets, or task working files.
- Do not commit memory packs or generated operator memory.
- Do not rewrite git history.
- Do not let agents share branches.
- Do not let agents edit the same file at the same time.
- Keep project-specific secrets out of docs and examples.
