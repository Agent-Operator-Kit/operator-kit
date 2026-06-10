---
name: operator
description: Manage Agent Operator Kit execution from Cursor. Use when the user mentions operator mode, task packets, tmux lanes, dispatch, collect, handoffs, lane status, worktree agents, or asks to execute approved roadmap work.
---

# Operator

Use this skill as Cursor's execution mode for an installed Agent Operator Kit
project. The project-local `operator.config.env` and `scripts/operator-*.sh`
files are the source of truth.

Do not treat this as direct tmux chat. Operate through status checks, task
packets, dispatch, collection, summaries, and reviewed integration.

For V4 feature-session orchestration, treat one Codex or Cursor project as the
operator cockpit. Bind execution chats to one feature session when possible,
and keep feature-session state under
`OPERATOR_DIR/features/<FS-id-slug>/`.

Mode split:

```text
operator-feedback = capture evidence, classify feedback, write FB-* intake
operator-planner  = prioritize, group, promote to roadmap/backlog
operator          = create tasks, dispatch lanes, collect, integrate
design-agent      = UX/design-system reasoning and UI task shaping
UX Auditor (ux-auditor) = scored UX assessment and recommendations
user-journey      = persona, ICP, journey map, blueprint, and storyboard artifacts
```

## Start Routine

1. Resolve the Operator Kit project:
   - walk upward until `operator.config.env` is found;
   - if needed, check the scoped project-root layout `code/*/operator.config.env`;
   - if needed, check sibling worktrees for the canonical project.
2. Read `operator.config.env` and `AGENTS.md`.
3. Confirm the install has `scripts/operator-status.sh`,
   `scripts/operator-task.sh`, `scripts/operator-dispatch.sh`,
   `scripts/operator-collect.sh`, `scripts/operator-summary.sh`, and
   `scripts/operator-memory.sh`, plus V2 scripts `scripts/operator-catalog.sh`,
   `scripts/operator-system-map.sh`, and `scripts/operator-plan-batch.sh`.
   V4 installs may also provide `scripts/operator-feature.sh` and
   `scripts/operator-conflicts.sh`; use them when present, but do not mark a V2
   install partial just because these newer commands are missing.
4. Run:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
```

If the install is partial or missing, report what is missing and do not dispatch
or collect until the project is repaired.

## Execution Commands

Prefer project-local scripts:

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-tmux.sh start-workers
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--no-enter] [--with-memory] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-roadmap.sh status
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
bash scripts/operator-feature.sh start|list|active|status|bind|link-roadmap|workspace|spawn-lane|close|archive|cleanup
bash scripts/operator-conflicts.sh check <feature>|summary
```

## V4 Feature Sessions

Operator V4 adds a feature-session layer above V2 tasks and lanes:

- a single Codex or Cursor project is the operator cockpit;
- a chat binds to one active feature session for execution context;
- feature state lives under `OPERATOR_DIR/features/<FS-id-slug>/`;
- lifecycle states are `idea`, `discovery`, `design`, `shaped`, `active`,
  `in-review`, `integrated`, `shipped`, `parked`, and `blocked`;
- role templates are duplicable into feature-specific lane instances;
- conflicts are based on touched surfaces, not role names alone;
- exploration can continue while implementation is blocked on a file, contract,
  branch, worktree, or shared resource.

When V4 commands exist, use `operator-feature.sh active` or
`operator-feature.sh bind` before execution, `operator-feature.sh workspace` for
the feature folder, and `operator-feature.sh spawn-lane` to create a
feature-specific lane instance from a role template.

Conflict review must check files, directories, API/schema/event/prompt/data and
design-system contracts, ports, databases, provider accounts, credentials,
simulators, fixtures, deployment targets, branches, and worktrees. Two lane
instances with the same role template may run in parallel when these surfaces
are disjoint; two different roles can conflict when they touch the same surface.

The operator owns the merge plan and final cohesion for the feature session.

For new work:

1. Check status and lane ownership first.
2. Bind to or create the relevant feature session when V4 commands are
   available.
3. Create the task folder with `operator-task.sh` for V2 execution, or use the
   V4 feature workspace when `operator-feature.sh workspace` is available.
4. Keep temporary working files under the feature workspace `work/` folder in
   V4, or under `OPERATOR_DIR/tasks/<slug>/work/` in V2.
5. Write lane packets under the feature or task `tasks/` folder.
6. Include goal, context, feature-session ID and lifecycle state when using V4,
   lane instance, role template, architecture patterns, approved packages/repos,
   owned files, read-only files, roadmap dependencies, touched surfaces,
   contracts, shared resources, parallel-safety notes, acceptance criteria,
   validation commands, handoff requirements, and memory candidates.
7. For roadmap-driven work, run `bash scripts/operator-plan-batch.sh` before dispatch.
8. For V4 work, run `bash scripts/operator-conflicts.sh check <feature>` when available
   before spawning or dispatching a lane instance.
9. Dispatch with `operator-dispatch.sh`, using `--with-memory` when prior
   context matters.
10. Collect, review the worker branch, validate, and integrate only approved
   source changes.

## Guardrails

- Do not let two agents share the same branch.
- Do not let two agents edit the same file area at the same time.
- Do not spawn or dispatch a V4 lane instance until branch, worktree, file,
  contract, and shared-resource conflicts are checked.
- Do not block unblocked exploration lanes merely because an implementation
  lane is resource- or file-blocked.
- Do not commit raw task packets, handoffs, pane captures, memory packs, or
  transient working files.
- Pause before destructive cleanup, credential changes, provider-console
  changes, production deploys, release submissions, or product decisions that
  cannot be safely inferred.
