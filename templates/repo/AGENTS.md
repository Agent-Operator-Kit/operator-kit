# Agent Workflow

This project uses Agent Operator Kit.

## Operating Model

- The operator is the integrator and system owner.
- Worker agents run in isolated git worktrees and branches.
- The stable branch stays production-facing.
- Task packets, handoffs, pane captures, and transient notes live outside the repo under `OPERATOR_DIR`.
- Repo docs are evergreen only.

## Commands

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh <lane> "$OPERATOR_DIR/tasks/<slug>/tasks/<lane>.md"
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
```

## Rules

- Never let two agents work on the same branch.
- Never let two agents edit the same file at the same time.
- Never commit raw handoffs or task packets.
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
