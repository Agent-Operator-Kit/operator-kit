# Operator Workflow Skill

Use this skill when a user asks to set up, restore, or operate a multi-agent workflow using git worktrees, tmux, external task packets, and operator-owned integration.

## Workflow

1. Inspect the project root and git status.
2. Identify default branch, package manager, and validation commands.
3. Propose or read a lane map.
4. Create an external operator workspace.
5. Install or update operator scripts and evergreen docs.
6. Create lane worktrees and branches.
7. Start tmux lanes.
8. Create a smoke task under the external operator workspace.
9. Dispatch and collect one smoke handoff when appropriate.
10. Report exact paths, branches, commands, and validation status.

## Agent-Run Setup

When the user wants an agent to fully set up the system from scratch, follow `docs/guides/agent-run-bootstrap.md` and the prompt template in `templates/prompts/agent-run-bootstrap.md`.

The setup agent should inspect first, propose a lane map, install scripts/templates, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

## Guardrails

- Do not commit raw handoffs, pane captures, or task packets.
- Do not rewrite git history.
- Do not let agents share branches.
- Do not let agents edit the same file at the same time.
- Keep project-specific secrets out of docs and examples.
