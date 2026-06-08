---
name: operator-planner
description: Plan Agent Operator Kit roadmap work from Cursor. Use when reviewing feedback, grouping themes, prioritizing now/next/later, promoting FB-* intake to RM-* roadmap items, or preparing lane-ready plans without dispatching agents.
---

# Operator Planner

Use this skill as Cursor's planning mode for an installed Agent Operator Kit
project.

Planning is not execution. Do not dispatch lanes, collect lane work, merge code,
or send text directly into tmux panes. The `operator` skill owns execution.

Mode split:

```text
operator-feedback = capture evidence, classify feedback, write FB-* intake
operator-planner  = prioritize, group, promote to roadmap/backlog
operator          = create tasks, dispatch lanes, collect, integrate
design-agent      = UX/design-system reasoning and UI task shaping
```

## Start Routine

1. Resolve the Operator Kit project:
   - walk upward until `operator.config.env` is found;
   - if needed, check the scoped project-root layout `code/*/operator.config.env`;
   - if needed, check sibling worktrees for the canonical project.
2. Read `operator.config.env` and `AGENTS.md`.
3. Inspect local state:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-roadmap.sh status
bash scripts/operator-memory.sh status
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
```

4. Read only the roadmap items, feedback inbox items, task handoffs, and task
   memory relevant to the planning question.

If Operator Kit is not installed, explain that planning mode needs an installed
project or a target project path.

## Planning Work

Convert raw feedback and rough requests into decisions:

- group duplicate `FB-*` items;
- identify themes, dependencies, blockers, and lane ownership;
- map work to V2 role templates, architecture patterns, touched contracts, and approval gates;
- prioritize using impact, urgency, effort, confidence, and lane capacity;
- promote selected feedback to `RM-*` roadmap/backlog items;
- decide now, next, later, parked, blocked, ready, or shipped;
- write rationale, acceptance criteria, and lane-aware dispatch plans;
- draft PR or commit trace notes.

Roadmap items should include:

- ID, type, status, priority, impact, effort, confidence, and areas;
- depends on, required roles, owner lane, contracts, parallel safe, and approval gate;
- source feedback, related tasks, related PRs or commits;
- problem, rationale, acceptance criteria, dispatch plan, and progress.

Mark an item `ready` only when it has clear acceptance criteria, lane ownership,
required roles/contracts, dependency metadata, approval gates, and a dispatch
plan that `operator` can safely turn into task packets.

## Commands

Use project-local scripts:

```bash
bash scripts/operator-roadmap.sh init
bash scripts/operator-roadmap.sh add "Title" --type feature --priority P2
bash scripts/operator-roadmap.sh list
bash scripts/operator-roadmap.sh status
bash scripts/operator-roadmap.sh ready
bash scripts/operator-roadmap.sh link-task RM-0001 task-slug
bash scripts/operator-plan-batch.sh
bash scripts/operator-roadmap.sh pr-note RM-0001 --feedback FB-0001 --task task-slug
bash scripts/operator-feedback.sh triage <feedback-slug>
```

Output should lead with the top recommendation, ready-for-execution items,
blocked decisions, feedback themes, now/next/later, proposed lane schedule, and
PR or commit trace notes when useful.
