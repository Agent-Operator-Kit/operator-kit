# Operator V4 Feature Sessions

Operator V4 treats a feature as a coordinated session that can move through
discovery, design, implementation, review, integration, and shipping without
losing the thread across chats or worker lanes.

## Core Model

A single Codex or Cursor project is the operator cockpit. It is the place where
the human and operator decide what is active, what is blocked, what can run in
parallel, and how worker output gets merged into one coherent feature.

Each active chat binds to a feature session. The binding gives natural requests
like `status`, `spawn a UI lane`, `check conflicts`, or `what is blocked?` a
specific feature context without making the whole repo the implicit target.

Feature-session state lives outside the repo:

```text
OPERATOR_DIR/
  features/
    FS-0007-checkout-recovery/
      feature.md
      status.json
      events.jsonl
      memory.md
      merge-plan.md
      lanes.md
      resources.md
      tasks/
      handoffs/
      work/
```

The exact file set can evolve, but the invariant is stable: generated packets,
handoffs, scratch work, captures, and feature memory stay under
`OPERATOR_DIR/features/<FS-id-slug>/` unless the operator intentionally promotes
something into durable source or evergreen docs.

## Lifecycle

Feature sessions use an explicit lifecycle:

```text
idea
discovery
design
shaped
active
in-review
integrated
shipped
parked
blocked
```

The practical meaning:

- `idea`: worth capturing, not yet shaped enough for execution.
- `discovery`: gathering context, constraints, user evidence, and system facts.
- `design`: exploring UX, architecture, API, data, or operational approach.
- `shaped`: scoped enough for lane packets, acceptance criteria, and conflicts.
- `active`: one or more lane instances are executing.
- `in-review`: worker output exists and the operator is reviewing, validating,
  and preparing integration.
- `integrated`: source changes are merged into the stable integration branch.
- `shipped`: released, handed off, or otherwise done from the product
  perspective.
- `parked`: intentionally paused without being a blocker.
- `blocked`: cannot make meaningful progress without a decision, credential,
  external dependency, resource, or conflict resolution.

## Role Templates And Lane Instances

V2 role templates remain useful, but in V4 they are templates for lane
instances, not global locks. `web-ui`, `api-contracts`, `design-system`, or
`evals-testing` describe how a worker should think and validate. They do not
mean only one worker with that role can exist across the whole project.

The operator can duplicate a role template into feature-specific lane instances,
for example:

```text
FS-0007/web-ui-a
FS-0007/web-ui-b
FS-0007/api-contracts
FS-0011/web-ui-a
```

Instances are allowed when their actual surfaces do not overlap unsafely. They
must still have separate branches or worktrees when doing source edits, scoped
task packets, and clear handoff requirements.

## Conflict Detection

V4 conflict detection is surface-based. The operator checks what work touches,
not just which role name is assigned.

Conflict surfaces include:

- source files and directories
- shared packages and generated artifacts
- API routes, schemas, migrations, events, prompts, and data contracts
- design tokens, components, navigation, content models, and copy contracts
- ports, databases, queues, caches, provider accounts, simulators, fixtures,
  credentials, and deployment targets
- branch and worktree ownership

Two lane instances with the same role can run in parallel when these surfaces
are disjoint. Two lane instances with different roles can conflict when they
touch the same contract, file area, resource, or validation environment.

Expected command shape:

```bash
bash scripts/operator-conflicts.sh check <feature>
bash scripts/operator-conflicts.sh summary
```

## Parallelism While Blocked

`blocked` should be precise. A blocked implementation surface does not
automatically block the whole feature session.

If a web implementation lane is blocked on an API contract, the operator can
continue discovery, design review, QA planning, fixture preparation, docs, or
architecture options in separate lane instances. The operator records the
blocked surface and keeps unblocked exploration moving until the session is
parked, resolved, or ready to integrate.

## Operator Responsibilities

The operator owns:

- binding chats to the active feature session
- lifecycle state and roadmap linkage
- feature workspace hygiene under `OPERATOR_DIR/features/<FS-id-slug>/`
- lane-instance spawning from role templates
- conflict checks across surfaces, files, contracts, and resources
- task packet quality and handoff requirements
- merge plan, sequencing, and final cohesion
- deciding when a feature is integrated, shipped, parked, or blocked

Workers own:

- scoped execution inside their assigned lane instance
- respecting owned/read-only surfaces
- recording validation evidence
- producing clean handoffs
- surfacing memory candidates and unresolved risks

## Expected Commands

The V4 command family is expected to look roughly like this:

```bash
bash scripts/operator-feature.sh start
bash scripts/operator-feature.sh list
bash scripts/operator-feature.sh active
bash scripts/operator-feature.sh status
bash scripts/operator-feature.sh bind
bash scripts/operator-feature.sh link-roadmap
bash scripts/operator-feature.sh workspace
bash scripts/operator-feature.sh spawn-lane
bash scripts/operator-feature.sh close
bash scripts/operator-feature.sh archive
bash scripts/operator-feature.sh cleanup

bash scripts/operator-conflicts.sh check <feature>
bash scripts/operator-conflicts.sh summary
```

Until every host adapter has first-class V4 commands, use existing V2 task,
dispatch, collect, memory, roadmap, system-map, catalog, and batch-planning
commands as the execution primitives. Keep V4 feature-session identity in the
packet, folder names, handoffs, and merge plan.
