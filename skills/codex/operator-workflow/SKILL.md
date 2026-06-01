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
4. In V2, initialize the system map, role catalog, architecture-pattern catalog, and lane recommendations.
5. Create an external operator workspace.
6. Install or update operator scripts, Operator Memory Router, local roadmap/feedback workspace, and evergreen docs.
7. Install Claude Code project assets under `.claude/` when the target project uses Claude Code.
8. Install Cursor project assets under `.cursor/` when the target project uses Cursor.
9. Create lane worktrees and branches.
10. Start tmux lanes.
11. Create a smoke task under the external operator workspace.
12. Verify `scripts/operator-memory.sh status`, `scripts/operator-roadmap.sh status`, `scripts/operator-catalog.sh list roles`, and `scripts/operator-recommend-lanes.sh`.
13. Dispatch and collect one smoke handoff when appropriate.
14. Report exact paths, branches, commands, V2 catalog/system-map status, memory/roadmap status, and validation status.

## Agent-Run Setup

When the user wants an agent to fully set up the system from scratch, follow `docs/guides/agent-run-bootstrap.md` and the prompt template in `templates/prompts/agent-run-bootstrap.md`.

The setup agent should inspect first, refresh the V2 system map and lane
recommendations, propose a lane map, install scripts/templates, create the
external operator workspace, create or verify worktrees, start tmux, run a smoke
task, and report whether the repo is ready to commit.

## V2 Catalog And Batch Planning

Installed V2 projects should include:

```bash
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
```

The catalog is the engineering-pattern source of truth for specialist roles,
approved packages/repos, validation recipes, and escalation gates. The batch
planner is advisory and requires operator approval before dispatch.

## Memory

Installed projects should include `scripts/operator-memory.sh` and
`OPERATOR_DIR/memory/`. Use task memory for feature-track facts, project memory
for durable cross-task facts, and `operator-dispatch.sh --with-memory` only
when retrieved context is relevant to the target lane.

## Roadmap And Feedback

Installed projects should include `scripts/operator-roadmap.sh`,
`scripts/operator-feedback.sh`, and `OPERATOR_DIR/roadmap/`. Keep local roadmap,
backlog, prioritization, raw feedback, screenshot/video annotations, and
planning views outside the app repo. Use PR/commit trace IDs for code-level
rationale.

For Codex Desktop daily use, keep the mode split explicit:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

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
