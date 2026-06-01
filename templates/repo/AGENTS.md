# Agent Workflow

This project uses Agent Operator Kit.

`operator.config.env` and `scripts/operator-*.sh` are the source of truth for lanes, worktrees, tmux, task packets, dispatch, collection, summaries, V2 system maps/catalogs, batch planning, and Operator Kit updates.

When operating from Cursor, read `.cursor/rules/operator-workflow.mdc`. Use `.cursor/skills/operator/SKILL.md` for day-to-day execution, `.cursor/skills/operator-planner/SKILL.md` for roadmap/backlog planning, `.cursor/skills/operator-feedback/SKILL.md` for feedback intake, `.cursor/skills/design-agent/SKILL.md` for UX/design work, `.cursor/skills/ux-auditor/SKILL.md` for scored UX audits, `.cursor/skills/user-journey/SKILL.md` for journey artifacts, `.cursor/skills/incubation/SKILL.md` for idea incubation and promotion readiness, and `.cursor/skills/operator-workflow/SKILL.md` for setup, status, dispatch, collection, and repair workflows. In Cursor-first environments without Codex, use Cursor IDE as the operator lane, Cursor CLI as a local worker lane when available, and Claude Code as an optional scoped worker.

When operating from Codex Desktop, use `$operator-feedback` for feedback intake, `$operator-planner` for roadmap/backlog planning, `$design-agent` for UX/design-system work, UX Auditor (`$ux-auditor`) for scored UX audits, `$user-journey` for journey artifacts, `$incubation` for idea incubation and promotion readiness, and `$operator` for execution unless the user explicitly says otherwise.

If the user says to always use operator for the current project or session, make
operator mode the default for future execution requests in Cursor and Codex.
Still route observation-only work to feedback mode, prioritization to planner
mode, UX/design-system work to design-agent mode, scored UX assessment to
UX Auditor mode, journey artifact creation to user-journey mode, and idea
incubation to incubation mode unless the user asks for execution.

## Operating Model

- The operator is the integrator and system owner.
- Worker agents run in isolated git worktrees and branches.
- The stable branch stays production-facing.
- Task packets, handoffs, pane captures, task working files, and transient notes live outside the repo under `OPERATOR_DIR`.
- Repo docs are evergreen only.
- Feedback is not execution: annotations and testing notes become `FB-*` intake first, planner work promotes selected items into `RM-*`, and only `$operator` dispatches implementation.
- V2 role templates and architecture patterns live under `OPERATOR_DIR/catalog`; use them like an engineering design system for approved packages, repos, contracts, and validation patterns.

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
bash scripts/operator-roadmap.sh status
bash scripts/operator-feedback.sh detect
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>]
bash scripts/operator-upgrade.sh [--dry-run] [--projects-root <path>] [--target <repo>]
```

## Memory

- `AGENTS.md` is evergreen repo guidance.
- `OPERATOR_DIR/memory/project.md` stores durable project facts.
- `OPERATOR_DIR/tasks/<slug>/memory.md` stores feature-track facts shared across lanes.
- `OPERATOR_DIR/tasks/<slug>/work/` stores temporary working files: scratch markdown, prototypes, screenshots, generated images, redesign options, and review READMEs.
- `OPERATOR_DIR/roadmap/` stores local roadmap, backlog, feedback, prioritization views, and PR/commit trace IDs.
- `OPERATOR_DIR/system-map.md` and `OPERATOR_DIR/catalog/` store V2 lane recommendations, role templates, and architecture patterns.
- `OPERATOR_DIR/memory/episodes/*.md` stores distilled lane handoffs.
- Use `operator-dispatch.sh --with-memory` when prior context should be retrieved for a lane.
- Raw captures and handoffs are evidence; promote only concise facts that will help future work.

## Rules

- Never let two agents work on the same branch.
- Never let two agents edit the same file at the same time.
- Never commit raw handoffs or task packets.
- Never commit task working files unless the operator explicitly promotes them into durable source or docs.
- Never commit raw roadmap inbox items, local feedback annotations, or planning views unless explicitly promoted into evergreen docs.
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
