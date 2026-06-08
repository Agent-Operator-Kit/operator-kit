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

Mode split:

```text
operator-feedback = capture evidence, classify feedback, write FB-* intake
operator-planner  = prioritize, group, promote to roadmap/backlog
operator          = create tasks, dispatch lanes, collect, integrate
design-agent      = UX/design-system reasoning and UI task shaping
UX Auditor (ux-auditor) = scored UX assessment and recommendations
user-journey      = persona, ICP, journey map, blueprint, and storyboard artifacts
```

## Sticky Operator Mode

When the user initializes Operator for this Cursor chat or project, treat
sticky Operator mode as default routing, not automatic execution:

```text
operator off       # normal Cursor behavior
operator observe   # status, summaries, memory/roadmap reads, feedback/planning summaries
operator active    # observe plus feedback intake, planning, and task-packet creation
operator dispatch  # execution allowed only when the user clearly asks and preflight passes
```

Use `operator observe` as the safest default. Natural phrases such as `status`,
`what is blocked?`, and `summarize lanes` can route through Operator when
exactly one Operator config is bound. Dispatch, collection, source integration,
push, tag, release, destructive cleanup, provider changes, and credential
changes still require explicit intent, a clear target, preflight, and review.

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
```

For new work:

1. Check status and lane ownership first.
2. Create the task folder with `operator-task.sh`.
3. Keep temporary working files under `OPERATOR_DIR/tasks/<slug>/work/`.
4. Write lane packets under `OPERATOR_DIR/tasks/<slug>/tasks/`.
5. Include goal, context, role template, architecture patterns, approved
   packages/repos, owned files, read-only files, roadmap dependencies, touched
   contracts, parallel-safety notes, acceptance criteria, validation commands,
   handoff requirements, and memory candidates.
6. For roadmap-driven work, run `bash scripts/operator-plan-batch.sh` before dispatch.
7. Dispatch with `operator-dispatch.sh`, using `--with-memory` when prior
   context matters.
8. Collect, review the worker branch, validate, and integrate only approved
   source changes.

## Guardrails

- Do not let two agents share the same branch.
- Do not let two agents edit the same file area at the same time.
- Do not commit raw task packets, handoffs, pane captures, memory packs, or
  transient working files.
- Pause before destructive cleanup, credential changes, provider-console
  changes, production deploys, release submissions, or product decisions that
  cannot be safely inferred.
