---
name: operator
description: "Manage Agent Operator Kit execution in Codex Desktop. Use when the user mentions $operator, Agent Operator Kit execution, lanes, tmux lanes, task packets, dispatch, collect, handoffs, lane status, worktree agents, updating Operator Kit, or working in a promoted project that has operator.config.env and scripts/operator-*.sh. Use $operator-feedback for feedback intake and $operator-planner for roadmap planning."
---

# Operator

Use this skill as the Codex Desktop operating wrapper for an installed Agent Operator Kit project. The project-local `operator.config.env` and `scripts/operator-*.sh` files are the source of truth.

Do not treat this as direct tmux chat. Operate through status checks, task packets, dispatch, collection, summaries, and reviewed integration.

This is execution mode:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
UX Auditor ($ux-auditor) = scored UX assessment against persona, ICP, journey, and business fit
$user-journey      = persona, ICP, journey map, service blueprint, and storyboard artifacts
$operator          = create tasks, dispatch lanes, collect, integrate
```

When the user is only testing, annotating, collecting observations, or
prioritizing backlog, prefer `$operator-feedback` or `$operator-planner`.
Use UX Auditor (`$ux-auditor`) for assessment, `$user-journey` for journey
artifacts, and `$operator` when work is ready to become execution.

## Detect The Project

Before operator work, resolve the project root:

1. Starting from `pwd`, walk upward until `operator.config.env` is found.
2. If no config is found upward, check the scoped project-root layout
   `code/*/operator.config.env`; this lets the operator work when the chat is
   opened at the top-level project folder.
3. If no scoped root config is found, check sibling worktrees by walking upward
   and looking for immediate child directories that contain
   `operator.config.env`; this handles starting from `code/app-backend` while
   the canonical repo is `code/app`.
4. If multiple candidate configs are found, ask the user which project root to operate.
5. Confirm these scripts exist next to the selected config:
   - `scripts/operator-status.sh`
   - `scripts/operator-tmux.sh`
   - `scripts/operator-task.sh`
   - `scripts/operator-dispatch.sh`
   - `scripts/operator-collect.sh`
   - `scripts/operator-summary.sh`
   - `scripts/operator-memory.sh`
   - `scripts/operator-catalog.sh`
   - `scripts/operator-system-map.sh`
   - `scripts/operator-plan-batch.sh`
   - `scripts/operator-upgrade.sh`
6. Run all project-local Operator Kit commands with the selected project root as the working directory. If a command must be run from another directory, set `OPERATOR_CONFIG=<selected-root>/operator.config.env`.
7. Read `operator.config.env`.
8. Read `AGENTS.md` if present.
9. Classify the install:
   - `installed`: config and required scripts exist, and `bash scripts/operator-status.sh` runs.
   - `partial`: some detection files exist, but required files are missing or status fails.
   - `not-installed`: no reliable Operator Kit signals were found.

If installed, normally run:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
```

If partial, explain what was found and what is missing; do not dispatch or collect until repaired.
If not installed, say Operator Kit is not installed in this project and offer setup or a path switch.

## Core Commands

Prefer the project scripts over raw tmux or ad hoc filesystem work:

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-tmux.sh attach
bash scripts/operator-tmux.sh start-workers
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--no-enter] [--with-memory] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-memory.sh search <query>
bash scripts/operator-memory.sh promote project "<fact>"
bash scripts/operator-memory.sh promote task <slug> "<fact>"
bash scripts/operator-roadmap.sh status
bash scripts/operator-feedback.sh detect
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>]
bash scripts/operator-sync.sh [--target <repo>]
bash scripts/operator-upgrade.sh [--dry-run] [--projects-root <path>] [--target <repo>]
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
```

Avoid sending arbitrary text directly into tmux panes unless the scripts do not cover the use case.

## V2 Catalog, Lanes, And Batch Planning

Operator Kit V2 keeps V1 lanes/worktrees but adds a system map, role catalog,
approved architecture patterns, and dependency-aware batch planning.

Use these before broad planning or migration:

```bash
bash scripts/operator-system-map.sh refresh
bash scripts/operator-catalog.sh list roles
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
```

Lane recommendation principles:

- create durable lanes for long-lived ownership, explicit contract boundaries,
  high-risk domains, distinct validation loops, or high context/memory density;
- use role overlays when specialist guidance is useful but a permanent worktree
  would add coordination overhead;
- treat catalog patterns like an engineering design system: prefer approved
  frameworks, packages, repos, and solution patterns before inventing new ones.

`operator-plan-batch.sh` is advisory. It proposes operator-approved parallel
dispatch groups but never sends work to agents by itself.

## Upgrade Command

When the user says `$operator --upgrade`, `$operator /upgrade`, `operator upgrade`, or `upgrade Operator Kit`, run the upgrade workflow.

Preferred command from the kit source or an installed project:

```bash
bash scripts/operator-upgrade.sh
```

Use `--dry-run` when the user asks to preview changes:

```bash
bash scripts/operator-upgrade.sh --dry-run
```

Use `--target <repo>` for one project or `--projects-root <path>` for a project tree:

```bash
bash scripts/operator-upgrade.sh --target /path/to/project
bash scripts/operator-upgrade.sh --projects-root /path/to/projects
```

If the current project does not have `scripts/operator-upgrade.sh`, run it from the local kit source when available:

```bash
bash "$HOME/Projects/Agent-Operator-Kit/operator-kit/scripts/operator-upgrade.sh"
```

If no local source exists, use the latest GitHub source as the fallback:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
```

The upgrade command refreshes bundled Codex Desktop skills, discovers installed Operator Kit projects under `~/Projects` by default, refreshes each project's evergreen scripts/templates, and runs project checks. It preserves project-specific config, docs, handoffs, task packets, working files, memory, captures, and source code.

## Status And Summaries

For status requests:

1. Detect the project.
2. Run status and summary.
3. Summarize the lane map, branch health, dirty worktrees, tmux windows, latest handoffs, memory status, blockers, and stale lanes.
4. Mention risks before recommendations.

Keep the answer operational: what is safe to dispatch, what should be collected, what needs review, and what is blocked.

## Local Data Isolation

When a project has a persistent local environment used by the human for product feedback, protect it from agent automation:

1. Check the project docs and scripts for separate personal/local and agent/e2e profiles before running app servers, reset scripts, seed scripts, Playwright, Maestro, or integration tests.
2. Prefer the disposable agent/e2e profile for implementation validation, browser automation, reset/seed workflows, and worker handoff verification.
3. Use the persistent personal/local profile only when the user is manually testing curated data or explicitly asks to run that profile.
4. Do not run destructive reset, seed, fixture, or migration-cleanup commands against the human's persistent local database unless the user explicitly requests it and there is a backup or reversible path.
5. If the project has no local isolation yet and testing would pollute the human's data, recommend or implement a split before continuing with broad UI/backend validation.

Keep project-specific ports, database names, env files, and backup commands in the project repo docs. The reusable operator rule is: agent work should have a disposable sandbox, and human feedback data should be stable.

## Task Creation And Dispatch

For new work:

1. Check status first.
2. Clarify the target lane only if it cannot be inferred.
3. Create the task folder with `operator-task.sh`.
4. Use `$OPERATOR_DIR/tasks/<slug>/memory.md` for feature-track facts that should move across lanes.
5. Keep temporary working files under `$OPERATOR_DIR/tasks/<slug>/work/`.
6. Write lane task packets under `$OPERATOR_DIR/tasks/<slug>/tasks/`, not inside the repo.
7. Include:
   - goal
   - context
   - role template and architecture-pattern refs
   - approved packages/repos or a note that existing project patterns win
   - owned files or modules
   - read-only files or modules
   - roadmap dependencies, touched contracts, and parallel-safety notes
   - acceptance criteria
   - validation commands
   - expected working files under `$OPERATOR_DIR/tasks/<slug>/work/`
   - expected handoff output
   - `## Memory Candidates` handoff requirements
8. For roadmap-driven work, run `bash scripts/operator-plan-batch.sh` before dispatch and use its lane/approval/conflict findings in the packet.
9. Dispatch with `operator-dispatch.sh`, using `--no-enter` when review-before-send is safer and `--with-memory` when prior project, task, or lane context matters.

Before dispatch, check that no other active lane owns the same branch or file area.

## Cursor Collaboration

When Cursor is part of the project but Codex Desktop is acting as the main
operator, keep exactly one active operator cockpit for integration decisions.

Use `operator.config.env` as the binding lane map:

- If Codex is the integrator, the `operator` lane should normally be
  `operator|Codex Desktop|<repo>|<default-branch>|`.
- Use Cursor as named worker lanes such as `cursor`, `web`, or `agents-api`,
  each with its own worktree, branch, and command such as `cursor agent`.
- If the project was bootstrapped with the Cursor profile and says
  `operator|Cursor IDE|...`, call out the cockpit mismatch before dispatching
  implementation work from Codex. Either operate in status/review mode or make
  the lane map explicitly Codex-led before Codex starts integrating.

For local Cursor CLI lanes, use the normal Operator Kit dispatch flow:

```bash
bash scripts/operator-dispatch.sh [--with-memory] cursor "$OPERATOR_DIR/tasks/<slug>/tasks/cursor.md"
bash scripts/operator-collect.sh cursor <slug>
```

In Cursor lane task packets, tell the worker to read
`.cursor/rules/operator-workflow.mdc` and the relevant
`.cursor/skills/<mode>/SKILL.md`. Keep the packet self-contained enough that the
Cursor lane can produce a normal handoff without relying on Codex chat history.

Cursor Cloud Agents are remote branch workers, not local tmux lanes. Do not
assume they can read local `OPERATOR_DIR`, local Operator Memory, simulators, or
tmux panes. Put the task packet, relevant memory, validation commands, and
handoff requirements directly into the Cloud Agent prompt or PR context; collect
their work through the pushed branch or pasted handoff rather than local
`operator-collect.sh` unless a matching local worktree exists.

Preserve project-specific `.cursor/*` files during update and integration. Do
not let Cursor project rules weaken Operator Kit lane safety: one branch per
lane, no overlapping file ownership, no raw handoffs committed, and no
unreviewed worker merge into the stable branch.

## Design-Agent Collaboration

When the user asks for design, UX, UI consistency, design-system extraction, visual review, web-preview annotations, or starter-system recommendation:

1. If the request names `$design-agent` or clearly needs design-system/UX reasoning, suggest using `$design-agent` before dispatch unless the user already did.
2. Run normal operator detection, status, and summary before any lane work.
3. Ask for confirmation before dispatch when the design task is broad, subjective, or could touch many UI files.
4. Let `$design-agent` own the design/UX content:
   - scenario classification,
   - starter recommendation,
   - design-system extraction/audit,
   - annotation feedback classification,
   - acceptance criteria for design/UI tasks.
   - temporary design artifacts under `$OPERATOR_DIR/tasks/<slug>/work/`.
5. Keep `$operator` responsible for:
   - lane safety,
   - task folder creation under `$OPERATOR_DIR`,
   - dispatch,
   - collection,
   - integration review.

Suggested combined requests:

```text
Use $design-agent with $operator. Do a comprehensive UX and consistency review.
Use $design-agent with $operator. Extract a design system and prepare a UI lane task.
Use $design-agent with $operator-feedback. Capture my annotations as feedback.
Use $operator-planner with $operator. Turn ready design feedback into an execution plan.
```

Do not bypass `$operator` safety checks just because a task came from `$design-agent`. Do not let `design` and `ui` lanes edit the same files at the same time.

Design mockups, alternate redesign options, HTML prototypes, screenshots,
generated images, proposal READMEs, and other temporary design files belong in
`$OPERATOR_DIR/tasks/<slug>/work/`. Promote only accepted, durable artifacts
into source, `design-system/`, or evergreen docs.

## UX Auditor And Journey Collaboration

When the user asks for a UX score, UX audit, persona fit, ICP fit, journey-risk
assessment, user journey map, service blueprint, or storyboard:

1. Prefer UX Auditor (`$ux-auditor`) for scored assessment and prioritized recommendations.
2. Prefer `$user-journey` when the missing artifact is persona, ICP, journey map,
   service blueprint, storyboard, or first-value transition.
3. Use `$design-agent` when the work needs broader design-system extraction,
   visual consistency review, or UI task shaping.
4. Keep `$operator` responsible for project detection, lane safety, task folder
   creation, dispatch, collection, and integration review.

Suggested combined requests:

```text
Use $user-journey with $ux-auditor. Map this onboarding flow and score the experience.
Use $ux-auditor with $operator. Audit this flow and prepare implementation follow-ups.
Use $user-journey with $operator. Create a journey artifact, then shape a lane-ready task.
Use $ux-auditor with $operator-feedback. Capture audit findings as feedback intake.
```

Audit reports, journey maps, service blueprints, storyboards, Canvas exports,
HTML artifacts, screenshots, and other temporary review files belong under
`$OPERATOR_DIR/tasks/<slug>/work/` unless the operator intentionally promotes
them into durable source or docs.

## Incubation Collaboration

When the user asks about ideas, idea folders, product framing, promotion readiness, archiving, prioritization, or moving an idea from `$HOME/Incubation` into a real Operator Kit project:

1. If the request names `$incubation` or clearly needs idea-framing/promotion workflow, suggest using `$incubation` before Operator Kit setup unless the user already did.
2. Do not initialize Agent Operator Kit inside `$HOME/Incubation`.
3. Let `$incubation` own:
   - idea framing and contrarian critique,
   - durable markdown capture under `ideas/<slug>/`,
   - `promotion-brief.md`,
   - `_ops/promoted.md`, `_ops/archived.md`, and review-board updates.
4. Keep `$operator` responsible for:
   - setup only after the idea is promoted into `$HOME/Projects/<product-slug>/code/app`,
   - lane safety,
   - task folder creation under `$OPERATOR_DIR`,
   - dispatch,
   - collection,
   - integration review.

Suggested combined requests:

```text
Use $incubation with $operator. Prepare this idea for promotion, then tell me what Operator Kit setup would do.
Use $incubation with $operator. Promote this idea into $HOME/Projects and initialize Operator Kit only after I confirm.
Use $incubation with $design-agent. Turn the thesis into product and design-system assumptions before UI work.
```

Do not bootstrap lanes, create worktrees, or dispatch implementation agents from the Incubation workspace. Promotion is the handoff boundary.

## Collection And Integration Review

For collection:

1. Run `operator-collect.sh <lane> <slug>`.
2. Check the generated episode under `$OPERATOR_DIR/memory/episodes/`.
3. Inspect the lane worktree git status and diff.
4. Summarize:
   - what changed
   - working files created or reviewed
   - acceptance criteria met or missed
   - tests run and missing
   - memory candidates worth promoting
   - risks and blockers
   - integration recommendation

Do not merge worker branches into the stable branch without operator review. Do not commit raw handoffs, task packets, captures, task working files, or transient notes.

## Operator Memory

Use Operator Memory Router for context that should survive compaction and lane changes:

- `AGENTS.md`: committed evergreen repo guidance.
- `$OPERATOR_DIR/memory/project.md`: durable project facts and decisions.
- `$OPERATOR_DIR/tasks/<slug>/memory.md`: feature-track facts shared across lanes.
- `$OPERATOR_DIR/memory/episodes/*.md`: distilled lane handoffs from collection.

Before dispatch, search or pack memory only when it is relevant to the lane:

```bash
bash scripts/operator-memory.sh search "<query>"
bash scripts/operator-dispatch.sh --with-memory <lane> "$OPERATOR_DIR/tasks/<slug>/tasks/<lane>.md"
```

Promote facts intentionally:

```bash
bash scripts/operator-memory.sh promote project "<durable project fact>"
bash scripts/operator-memory.sh promote task <slug> "<feature-track fact>"
```

Raw captures are evidence, not durable memory. If a memory fact should guide every contributor and agent by default, move it into evergreen repo docs instead.

## Working Files

Use `$OPERATOR_DIR/tasks/<slug>/work/` for all temporary task artifacts:

- scratch markdown and review READMEs
- redesign options and proposals
- HTML prototypes and visual mockups
- screenshots, generated images, exported assets, and PDFs
- intermediate analysis that should not be committed

Keep working files outside the repo. Promote a file into source, `design-system/`,
or evergreen docs only when the operator intentionally accepts it as durable
project material.

## Local Roadmap And Feedback

Use `scripts/operator-roadmap.sh` and `scripts/operator-feedback.sh` for local
roadmap, backlog, feedback intake, simulator captures, and browser-based
annotation review. This state lives under `OPERATOR_DIR`, not the app repo.

Use `$operator-feedback` for feedback intake and `$operator-planner` for triage,
prioritization, rationale, and ready-for-execution shaping. Keep `$operator`
responsible for lane safety, task folder creation, dispatch, collection, and
integration review.

For mobile feedback, the default evidence model is:

```text
screenshot/video + screen + coordinates or testID + comment
```

Use lightweight trace references in PRs or commits:

```markdown
Roadmap: RM-0007
Feedback: FB-0014, FB-0015
Operator task: mobile-feedback-20260522
Why: short rationale
Validation: commands or manual checks
```

## Update To Latest

When the user says `$operator update to latest version from git` or similar:

1. Detect the project and classify the install.
2. Resolve the Operator Kit source:
   - prefer a local source repo at `$HOME/Projects/Agent-Operator-Kit/operator-kit` when it exists;
   - otherwise use `https://github.com/Agent-Operator-Kit/operator-kit.git`;
   - respect `OPERATOR_KIT_SOURCE` if the user or environment provides it.
3. If using a local source repo, run `git pull --ff-only` there only when it has no local changes. If it is dirty, report that and do not overwrite its changes.
4. Prefer the single-command sync script when available:
   ```bash
   bash <kit-source>/scripts/operator-sync.sh --source <kit-source> --target <project-root>
   ```
5. If running the lower-level steps manually, refresh bundled global Codex skills from the source:
   ```bash
   bash <kit-source>/scripts/codex-skills-install.sh --source <kit-source> --no-fetch
   ```
6. If the user only wants a subset, use `--skill <name>` for one or more skills. Otherwise install every bundled `skills/codex/*/SKILL.md` directory.
7. Refresh the installed project using `operator-update.sh`:
   ```bash
   bash scripts/operator-update.sh --source <kit-source> --target <project-root>
   ```
   If the project does not yet have `scripts/operator-update.sh`, run it from the source kit:
   ```bash
   bash <kit-source>/scripts/operator-update.sh --source <kit-source> --target <project-root>
   ```
8. Run:
   ```bash
   bash -n scripts/*.sh
   bash scripts/operator-status.sh
   bash scripts/operator-summary.sh
   bash scripts/operator-memory.sh status
   bash scripts/operator-catalog.sh list roles
   bash scripts/operator-recommend-lanes.sh
   bash scripts/operator-plan-batch.sh
   bash scripts/operator-upgrade.sh --dry-run --skip-skills --target <project-root>
   git status --short
   ```
9. Summarize source revision, updated files, installed missing files, preserved project-specific files, validation results, optional companion skills refreshed, and any manual follow-up.

The update flow must preserve project-specific files by default: `operator.config.env`, existing `AGENTS.md`, `CODEX.md`, `CLAUDE.md`, `.claude/*`, `.cursor/*`, raw handoffs, task packets, task working files, captures, and all source code.

## Guardrails

- Do not let two agents share the same branch.
- Do not let two lanes edit the same files at the same time.
- Keep generated operator state under `OPERATOR_DIR`.
- Keep temporary working files under `$OPERATOR_DIR/tasks/<slug>/work/`.
- Distill durable facts into operator memory or evergreen repo docs.
- Retrieve only context relevant to the current lane and task.
- Do not deploy, force-push, rewrite history, or commit secrets unless explicitly requested.
- Check git status before dispatch, collection, and integration decisions.

## Automations

Safe automation candidates are status, summary, and blocker checks:

- daily project status summary
- every 2 hours: check lanes for blockers
- end-of-day: summarize open tasks and stale lanes
- weekly: summarize momentum and unresolved risks

Avoid automating new implementation dispatch until the user explicitly trusts that workflow.
