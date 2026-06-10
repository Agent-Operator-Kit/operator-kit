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

## V4 Feature Sessions

Operator V4 keeps the same conservative integration model, but changes the
coordination unit from "one task in one lane" to "one feature session across
many lane instances."

A single Codex or Cursor project acts as the operator cockpit. Each chat should
bind to one active feature session so status, memory, dispatch, conflict checks,
and handoffs all resolve to the same feature folder under
`OPERATOR_DIR/features/<FS-id-slug>/`.

Feature sessions move through this lifecycle:

```text
idea -> discovery -> design -> shaped -> active -> in-review -> integrated -> shipped
                                             \-> blocked
                                             \-> parked
```

Role templates in `OPERATOR_DIR/catalog/roles/` are duplicable worker
blueprints, not mutexes. The operator can spawn feature-specific lane instances
from the same role template when their branches, worktrees, files, contracts,
resources, and validation loops do not conflict.

Conflict detection is based on the surfaces being touched, not the role name
alone:

- files and directories
- API, schema, event, prompt, and design-system contracts
- shared resources such as ports, databases, provider sandboxes, credentials,
  simulators, fixtures, and deployment targets
- branch and worktree ownership

This lets exploration continue while implementation is blocked by a file,
resource, or contract conflict. For example, a design, research, QA, or
architecture lane can keep shaping options while a web implementation lane waits
for a backend contract to settle.

The operator owns the merge plan, conflict policy, and final cohesion of the
feature session. Worker agents own scoped execution and handoff evidence.

Expected V4 command shape:

```bash
bash scripts/operator-feature.sh start|list|active|open|current|status|bind|link-roadmap|workspace|spawn-lane|close|archive|cleanup
bash scripts/operator-conflicts.sh check <feature>|summary
```

Codex, Cursor, and other host adapters should use `open`, `current`, and the
`--json` output flags as their native feature-session protocol, while keeping
`OPERATOR_DIR/features` as the source of truth. See
[Operator V4 feature sessions](operator-v4-feature-sessions.md) for the full
model.

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

## Sticky Operator Mode

Sticky Operator mode reduces repeated activation syntax for chats that are
already bound to an Operator project, but it does not change execution
authority. Natural phrases such as `status`, `what is blocked?`, and `summarize
lanes` can route through Operator by default in observe or stronger modes.

Mutating actions still need explicit intent, a clear target, and the normal
Operator preflight. See [Sticky Operator mode](sticky-operator-mode.md) for the
binding rules, mode semantics, and host adapter caveats.

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
