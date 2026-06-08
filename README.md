# Agent Operator Kit

Agent Operator Kit is a small operating model for running multiple coding
agents without losing control of the repo.

It gives Codex, Claude Code, Cursor, and other agents a shared workflow:
isolated worktree lanes, explicit task packets, external handoffs, file-first
memory, and operator-reviewed integration.

Website:

```text
https://agent-operator-kit.github.io/operator-kit/
```

## What It Solves

Most production work is not just "frontend plus backend." Real projects have
provider integrations, mobile release lanes, auth and permissions, knowledge
bases, observability, deployment, data, and domain-specific workflows.

Agent Operator Kit helps split that work into clear lanes:

- one operator owns integration decisions
- workers run in named lanes such as `backend`, `ui`, `provider`, or `release`
- each lane has its own branch and git worktree
- tmux keeps long-running local agents visible
- task packets, handoffs, screenshots, notes, and scratch files live outside the repo
- roadmap and feedback IDs stay traceable without committing the whole planning ledger

## Current Model

The current kit is the default on `main`.

It keeps the V1 worktree, tmux, task-packet, and handoff model, then adds:

- a project system map
- a role-template catalog
- approved architecture patterns
- lane recommendations
- dependency-aware batch planning
- operator approval before parallel dispatch

V1 remains available at the `v1` git tag:

```bash
git clone --branch v1 https://github.com/Agent-Operator-Kit/operator-kit.git
```

## Quick Start

Open Codex, Claude Code, Cursor, or another coding agent inside the target repo
and paste:

```text
Install or initialize Agent Operator Kit for this repo.

Use this source kit:
git@github.com:Agent-Operator-Kit/operator-kit.git

First clone or read the kit, then follow:
templates/prompts/agent-run-bootstrap.md
docs/guides/agent-run-bootstrap.md

Requirements:
- inspect the repo first
- detect whether Operator Kit is installed, partial, or missing
- install or migrate the kit without overwriting project-specific files
- recommend durable lanes for Codex, Claude Code, Cursor, or another agent
- create the external operator workspace outside the repo
- run smoke checks and report the lane map, OPERATOR_DIR, and git status

Guardrails:
- do not rewrite git history
- do not force-push
- do not commit secrets, raw handoffs, task packets, or transient notes
- do not deploy or run production builds during setup
```

Manual install from a local kit checkout:

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git
cd operator-kit
bash scripts/operator-sync.sh --target /path/to/your/repo --bootstrap-if-missing
```

For an empty scoped project root, point sync at the root folder. It will create
`code/app` as the canonical repo worktree and keep Operator state beside
`code/`:

```bash
mkdir -p "$HOME/Projects/acme"
bash scripts/operator-sync.sh --target "$HOME/Projects/acme" --bootstrap-if-missing
```

## Recommended Layout

```text
~/Projects/acme/
  code/
    app/             # canonical repo worktree
    app-backend/     # optional worker lane
    app-ui/          # optional worker lane
  operator/
    system-map.md
    catalog/
      roles/
      patterns/
    roadmap/
    tasks/
    memory/
```

Installed project assets include:

```text
operator.config.env
AGENTS.md
.claude/
.cursor/
scripts/operator-*.sh
```

## Core Commands

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--with-memory] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-memory.sh status
bash scripts/operator-roadmap.sh status
bash scripts/operator-feedback.sh detect
bash scripts/operator-system-map.sh refresh
bash scripts/operator-catalog.sh list roles
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
bash scripts/operator-sync.sh --target /path/to/project
bash scripts/operator-upgrade.sh
```

Remote update entry point:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
```

Pin V1 for a project:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/v1/scripts/operator-sync.sh) --target /path/to/repo
```

## Agent Assets

Codex Desktop skills:

```text
skills/codex/operator/SKILL.md
skills/codex/operator-workflow/SKILL.md
skills/codex/operator-feedback/SKILL.md
skills/codex/operator-planner/SKILL.md
skills/codex/design-agent/SKILL.md
skills/codex/ux-auditor/SKILL.md
skills/codex/user-journey/SKILL.md
skills/codex/incubation/SKILL.md
```

Claude Code assets:

```text
templates/claude/commands/operator-bootstrap.md
templates/claude/commands/operator-status.md
templates/claude/agents/operator-workflow.md
skills/claude-code/operator-workflow/SKILL.md
```

Cursor assets:

```text
templates/cursor/rules/operator-workflow.mdc
templates/cursor/skills/
templates/cursor/environment.json.example
templates/prompts/cursor-agent-bootstrap.md
```

Install or refresh Codex Desktop skills:

```bash
bash scripts/codex-skills-install.sh
```

## Docs

- [Agent-run bootstrap](docs/guides/agent-run-bootstrap.md)
- [Getting started with agents](docs/guides/getting-started-with-agents.md)
- [Cursor operator workflow](docs/guides/cursor-operator-workflow.md)
- [Sticky Operator mode](docs/concepts/sticky-operator-mode.md)
- [Operator memory](docs/concepts/operator-memory.md)
- [Operator roadmap](docs/concepts/operator-roadmap.md)
- [Design-agent collaboration](docs/guides/design-agent-collaboration.md)
- [Incubation collaboration](docs/guides/incubation-collaboration.md)

## Rules

- Do not let two agents share the same branch.
- Do not let two lanes edit the same files at the same time.
- Keep generated operator state under `OPERATOR_DIR`.
- Keep temporary work under `OPERATOR_DIR/tasks/<slug>/work/`.
- Do not commit raw handoffs, task packets, pane captures, memory packs, or transient notes.
- Do not merge worker branches into `main` without operator review.

## Status

The current kit is on `main`. V1 is preserved at the `v1` tag. The scripts are
intentionally small and inspectable; a richer CLI can wrap the same model later.
