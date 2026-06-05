# Operator Model

The operator is the integrator and system owner. Worker agents execute scoped tasks in isolated lanes.

The operator owns:

- lane assignment
- system-map and role-template recommendations
- architecture-pattern catalog curation
- dependency-aware batch planning before parallel dispatch
- branch and worktree policy
- dispatching task packets
- keeping temporary working files outside the repo
- routing relevant memory into dispatch context packs
- collecting handoffs
- distilling lane episodes into durable task or project memory
- reviewing diffs
- final integration into the stable branch
- keeping an authorized feature track moving across lanes until it is done or
  blocked

Worker agents own:

- scoped implementation within their assigned lane
- respecting the role contract and approved architecture patterns in the task packet
- clear handoffs
- validation evidence
- respecting file and branch boundaries

This model is intentionally conservative. It favors traceability and integration quality over agents freely editing the same branch.

## V2 Catalog And Scheduler

Operator V2 keeps this conservative execution model but adds more planning
context:

- `OPERATOR_DIR/system-map.md` maps the project architecture, current lanes, and
  recommended specialist roles.
- `OPERATOR_DIR/catalog/roles/` stores reusable specialist role templates.
- `OPERATOR_DIR/catalog/patterns/` stores approved architecture patterns,
  packages, repos, and validation recipes.
- `scripts/operator-plan-batch.sh` proposes operator-approved parallel dispatch
  groups from roadmap dependencies and lane ownership.

Durable lanes are recommended for long-lived ownership, contract boundaries,
high-risk domains, distinct validation loops, or high context density. Smaller
specialist work should run as role overlays before it becomes a permanent lane.

## Working Files

Each task has a working folder at `OPERATOR_DIR/tasks/<slug>/work/`.
Temporary artifacts belong there: scratch markdown, review notes, redesign
options, HTML prototypes, screenshots, generated images, exported assets, PDFs,
and proposal READMEs.

The repo should receive only durable source, evergreen docs, or promoted
design-system material. If a working artifact becomes durable, the operator
promotes it intentionally and records that in the handoff or task memory.

## Feature-Track Autonomy

For an authorized feature track, the operator should not stop after every
handoff just to ask whether to dispatch the obvious next lane. The operator
should keep coordinating follow-up work until the feature is completed,
integrated, validated, or blocked.

The operator should pause for user input when the next step changes product
direction, requires credentials, touches provider consoles, runs destructive
cleanup, starts a deployment or release submission, or enables regulated,
financial, or safety-critical behavior.

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
