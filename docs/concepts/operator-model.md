# Operator Model

The operator is the integrator and system owner. Worker agents execute scoped tasks in isolated lanes.

The operator owns:

- lane assignment
- branch and worktree policy
- dispatching task packets
- routing relevant memory into dispatch context packs
- collecting handoffs
- distilling lane episodes into durable task or project memory
- reviewing diffs
- final integration into the stable branch
- keeping an authorized feature track moving across lanes until it is done or
  blocked

Worker agents own:

- scoped implementation within their assigned lane
- clear handoffs
- validation evidence
- respecting file and branch boundaries

This model is intentionally conservative. It favors traceability and integration quality over agents freely editing the same branch.

## Feature-Track Autonomy

For an authorized feature track, the operator should not stop after every
handoff just to ask whether to dispatch the obvious next lane. The operator
should keep coordinating follow-up work until the feature is completed,
integrated, validated, or blocked.

The operator should pause for user input when the next step changes product
direction, requires credentials, touches provider consoles, runs destructive
cleanup, starts a deployment or release submission, or enables live-money /
production trading behavior.

## Memory Routing

Operator Kit treats memory as retrieved context, not as an always-on prompt
dump. The operator keeps evergreen rules in repo docs, durable project facts in
`OPERATOR_DIR/memory/project.md`, feature-track facts in
`OPERATOR_DIR/tasks/<slug>/memory.md`, and distilled lane handoffs in
`OPERATOR_DIR/memory/episodes/`.

Before dispatch, the operator can add `--with-memory` to build a compact
context pack for one lane and one task. The task packet still wins if there is
a conflict. After collection, the raw handoff is preserved as evidence and a
short episode memory file is generated for retrieval.
