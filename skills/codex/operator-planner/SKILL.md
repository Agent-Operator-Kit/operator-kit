---
name: operator-planner
description: "Use as Operator Kit planning mode: review FB-* intake, group themes, prioritize, promote to RM-* roadmap/backlog items, draft rationale and lane-ready plans, without dispatching implementation agents."
---

# Operator Planner

Use this skill when the user wants to review feedback, prioritize backlog,
shape roadmap items, decide now/next/later, or prepare implementation plans
before execution.

This is planning mode:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

Planning is not execution. Do not dispatch lanes, collect lane work, merge code,
or send text directly into tmux panes. `$operator` remains responsible for lane
safety and implementation handoff.

## Start Routine

1. Detect the Operator Kit project the same way `$operator` does:
   - walk upward for `operator.config.env`;
   - if needed, check sibling worktrees for the canonical project.
2. Read `operator.config.env` and `AGENTS.md`.
3. Inspect local state:
   - `bash scripts/operator-status.sh`
   - `bash scripts/operator-summary.sh`
   - `bash scripts/operator-roadmap.sh status`
   - `bash scripts/operator-memory.sh status`
4. Read only the relevant roadmap items, feedback inbox items, task handoffs,
   and task memory for the planning question.

If Operator Kit is not installed, explain that planning mode needs an installed
project or a target project path.

## What This Skill Owns

Convert raw feedback into decisions:

- group duplicate `FB-*` items;
- identify themes and dependencies;
- assign priority using impact, urgency, effort, confidence, and lane capacity;
- promote selected feedback to `RM-*` roadmap/backlog items;
- decide now/next/later, parked, blocked, ready, or shipped;
- write rationale and acceptance criteria;
- draft lane-aware implementation plans;
- draft PR/commit trace notes.

Roadmap item contract:

- `ID`
- `type`
- `status`
- `priority`
- `impact`
- `effort`
- `confidence`
- `areas`
- `source feedback`
- `related operator tasks`
- `related PRs/commits`
- `problem`
- `rationale`
- `acceptance criteria`
- `dispatch plan`
- `progress`

Statuses:

```text
idea -> candidate -> planned -> ready -> dispatched -> in-review -> shipped
                    \-> parked
                    \-> blocked
                    \-> superseded
```

Mark an item `ready` only when it has clear acceptance criteria, lane ownership,
and a dispatch plan that `$operator` can safely turn into task packets.

## Commands

Use project-local scripts:

```bash
bash scripts/operator-roadmap.sh init
bash scripts/operator-roadmap.sh add "Title" --type feature --priority P2
bash scripts/operator-roadmap.sh list
bash scripts/operator-roadmap.sh status
bash scripts/operator-roadmap.sh ready
bash scripts/operator-roadmap.sh link-task RM-0001 task-slug
bash scripts/operator-roadmap.sh pr-note RM-0001 --feedback FB-0001 --task task-slug

bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

Use `operator-feedback.sh triage` only when raw review annotations need to become
`FB-*` inbox files before planning. New capture/review work belongs to
`$operator-feedback`.

## Execution Boundary

The planner may draft lane-ready plans, but `$operator` should create execution
task folders, check lane and file conflicts, dispatch, collect, and integrate.

Use this handoff language:

```text
Ready for execution:
- Roadmap: RM-0007
- Feedback: FB-0014, FB-0015
- Proposed operator task: mobile-chat-input-polish
- Owner lane: mobile-ui
- Acceptance: ...
- Validation: ...
```

Then the user can invoke:

```text
Use $operator. Execute RM-0007 / FB-0014 with the proposed mobile-ui task.
```

## Output Style

Lead with:

- top recommendation;
- ready-for-execution items;
- blocked decisions;
- feedback themes;
- now/next/later;
- proposed lane schedule;
- PR/commit trace note when useful.

Keep tradeoffs explicit. Do not reduce prioritization to a score; explain the
choice in terms of user impact, urgency, effort, confidence, dependencies, and
lane availability.
