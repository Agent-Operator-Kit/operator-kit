---
name: operator
description: "Manage Agent Operator Kit projects in Codex Desktop. Use when the user mentions $operator, Agent Operator Kit, operator lanes, tmux lanes, task packets, dispatch, collect, handoffs, lane status, worktree agents, updating Operator Kit, design-agent collaboration, incubation promotion, or when working in a promoted project that has operator.config.env and scripts/operator-*.sh."
---

# Operator

Use this skill as the Codex Desktop operating wrapper for an installed Agent Operator Kit project. The project-local `operator.config.env` and `scripts/operator-*.sh` files are the source of truth.

Do not treat this as direct tmux chat. Operate through status checks, task packets, dispatch, collection, summaries, and reviewed integration.

## Detect The Project

Before operator work, resolve the project root:

1. Starting from `pwd`, walk upward until `operator.config.env` is found.
2. If no config is found upward, check sibling worktrees by walking upward and looking for immediate child directories that contain `operator.config.env`; this handles starting from `code/app-backend` while the canonical repo is `code/app`.
3. If multiple candidate configs are found, ask the user which project root to operate.
4. Confirm these scripts exist next to the selected config:
   - `scripts/operator-status.sh`
   - `scripts/operator-tmux.sh`
   - `scripts/operator-task.sh`
   - `scripts/operator-dispatch.sh`
   - `scripts/operator-collect.sh`
   - `scripts/operator-summary.sh`
5. Read `operator.config.env`.
6. Read `AGENTS.md` if present.
7. Classify the install:
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
bash scripts/operator-dispatch.sh [--no-enter] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>]
bash scripts/operator-sync.sh [--target <repo>]
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
```

Avoid sending arbitrary text directly into tmux panes unless the scripts do not cover the use case.

## Status And Summaries

For status requests:

1. Detect the project.
2. Run status and summary.
3. Summarize the lane map, branch health, dirty worktrees, tmux windows, latest handoffs, blockers, and stale lanes.
4. Mention risks before recommendations.

Keep the answer operational: what is safe to dispatch, what should be collected, what needs review, and what is blocked.

## Task Creation And Dispatch

For new work:

1. Check status first.
2. Clarify the target lane only if it cannot be inferred.
3. Create the task folder with `operator-task.sh`.
4. Write lane task packets under `$OPERATOR_DIR/tasks/<slug>/tasks/`, not inside the repo.
5. Include:
   - goal
   - context
   - owned files or modules
   - read-only files or modules
   - acceptance criteria
   - validation commands
   - expected handoff output
6. Dispatch with `operator-dispatch.sh`, using `--no-enter` when review-before-send is safer.

Before dispatch, check that no other active lane owns the same branch or file area.

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
Use $design-agent with $operator. Turn my annotations into a design follow-up task.
```

Do not bypass `$operator` safety checks just because a task came from `$design-agent`. Do not let `design` and `ui` lanes edit the same files at the same time.

## Incubation Collaboration

When the user asks about ideas, idea folders, product framing, promotion readiness, archiving, prioritization, or moving an idea from `/Users/norbert/Incubation` into a real Operator Kit project:

1. If the request names `$incubation` or clearly needs idea-framing/promotion workflow, suggest using `$incubation` before Operator Kit setup unless the user already did.
2. Do not initialize Agent Operator Kit inside `/Users/norbert/Incubation`.
3. Let `$incubation` own:
   - idea framing and contrarian critique,
   - durable markdown capture under `ideas/<slug>/`,
   - `promotion-brief.md`,
   - `_ops/promoted.md`, `_ops/archived.md`, and review-board updates.
4. Keep `$operator` responsible for:
   - setup only after the idea is promoted into `/Users/norbert/Projects/<product-slug>/code/app`,
   - lane safety,
   - task folder creation under `$OPERATOR_DIR`,
   - dispatch,
   - collection,
   - integration review.

Suggested combined requests:

```text
Use $incubation with $operator. Prepare this idea for promotion, then tell me what Operator Kit setup would do.
Use $incubation with $operator. Promote this idea into /Users/norbert/Projects and initialize Operator Kit only after I confirm.
Use $incubation with $design-agent. Turn the thesis into product and design-system assumptions before UI work.
```

Do not bootstrap lanes, create worktrees, or dispatch implementation agents from the Incubation workspace. Promotion is the handoff boundary.

## Collection And Integration Review

For collection:

1. Run `operator-collect.sh <lane> <slug>`.
2. Inspect the lane worktree git status and diff.
3. Summarize:
   - what changed
   - acceptance criteria met or missed
   - tests run and missing
   - risks and blockers
   - integration recommendation

Do not merge worker branches into the stable branch without operator review. Do not commit raw handoffs, task packets, captures, or transient notes.

## Update To Latest

When the user says `$operator update to latest version from git` or similar:

1. Detect the project and classify the install.
2. Resolve the Operator Kit source:
   - prefer a local source repo at `/Users/norbert/Projects/Agent-Operator-Kit/operator-kit` when it exists;
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
   git status --short
   ```
9. Summarize source revision, updated files, installed missing files, preserved project-specific files, validation results, optional companion skills refreshed, and any manual follow-up.

The update flow must preserve project-specific files by default: `operator.config.env`, existing `AGENTS.md`, `CODEX.md`, `CLAUDE.md`, `.claude/*`, `.cursor/*`, raw handoffs, task packets, captures, and all source code.

## Guardrails

- Do not let two agents share the same branch.
- Do not let two lanes edit the same files at the same time.
- Keep generated operator state under `OPERATOR_DIR`.
- Distill durable facts into evergreen repo docs.
- Do not deploy, force-push, rewrite history, or commit secrets unless explicitly requested.
- Check git status before dispatch, collection, and integration decisions.

## Automations

Safe automation candidates are status, summary, and blocker checks:

- daily project status summary
- every 2 hours: check lanes for blockers
- end-of-day: summarize open tasks and stale lanes
- weekly: summarize momentum and unresolved risks

Avoid automating new implementation dispatch until the user explicitly trusts that workflow.
