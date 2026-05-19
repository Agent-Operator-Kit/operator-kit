# Agent Workflow

This project uses Agent Operator Kit.

When operating this project in Codex Desktop, use the global `$operator` skill by default unless the user explicitly says otherwise. `operator.config.env` and `scripts/operator-*.sh` are the source of truth for lanes, worktrees, tmux, task packets, dispatch, collection, summaries, and Operator Kit updates.

## Operating Model

- The operator is the integrator and system owner.
- Worker agents run in isolated git worktrees and branches.
- The stable branch stays production-facing.
- Task packets, handoffs, pane captures, task working files, and transient notes live outside the repo under `OPERATOR_DIR`.
- Repo docs are evergreen only.

## Commands

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--with-memory] <lane> "$OPERATOR_DIR/tasks/<slug>/tasks/<lane>.md"
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-memory.sh search <query>
bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>]
bash scripts/operator-upgrade.sh [--dry-run] [--projects-root <path>] [--target <repo>]
```

## Memory

- `AGENTS.md` is evergreen repo guidance.
- `OPERATOR_DIR/memory/project.md` stores durable project facts.
- `OPERATOR_DIR/tasks/<slug>/memory.md` stores feature-track facts shared across lanes.
- `OPERATOR_DIR/tasks/<slug>/work/` stores temporary working files: scratch markdown, prototypes, screenshots, generated images, redesign options, and review READMEs.
- `OPERATOR_DIR/memory/episodes/*.md` stores distilled lane handoffs.
- Use `operator-dispatch.sh --with-memory` when prior context should be retrieved for a lane.
- Raw captures and handoffs are evidence; promote only concise facts that will help future work.

## Rules

- Never let two agents work on the same branch.
- Never let two agents edit the same file at the same time.
- Never commit raw handoffs or task packets.
- Never commit task working files unless the operator explicitly promotes them into durable source or docs.
- Merge worker work only after operator review and validation.

## Operator Dispatch Rule

- Once a user authorizes a feature track, the operator should keep
  dispatching necessary lane follow-ups until the feature is completed,
  integrated, validated, or blocked by a decision only the user can make.
- The operator should monitor worker lanes, collect handoffs, inspect git
  state, and route follow-up work to the appropriate lane without asking the
  user to approve every handoff-to-handoff transition.
- Pause for user input before destructive cleanup, credential changes,
  provider-console changes, production deploys, release submissions, live-money
  trading enablement, or product decisions that cannot be safely inferred.
