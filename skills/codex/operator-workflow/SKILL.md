---
name: operator-workflow
description: "Use for Agent Operator Kit setup, bootstrap, repair, and feature-track workflow guidance in Codex. Use when installing Operator Kit into a project, repairing a partial install, creating external operator workspaces, setting up tmux lanes and git worktrees, or validating smoke-task handoffs."
---

# Operator Workflow Skill

Use this skill when a user asks Codex to set up or repair an Agent Operator Kit installation using git worktrees, tmux, external task packets, and operator-owned integration.

For day-to-day operation inside an already installed project, prefer the runtime `$operator` skill in `skills/codex/operator/SKILL.md`.

## Global Plugin To Project Install

When Agent Operator Kit is globally available as a Codex plugin, the plugin
only supplies skills and routing. A project becomes operable after explicit
project-local setup. Treat phrases like `operator install`, `operator init`,
`install Operator here`, `set up Operator for this project`, and `bootstrap
Operator in this repo` as setup requests.

Setup from the global plugin must:

1. Resolve the target project path from the user request, or use the current
   working directory when no explicit target is given.
2. Inspect the target and git status before writing files.
3. Run `operator-sync.sh` with `--bootstrap-if-missing` and `--skip-skills`.
   Global skills are owned by the plugin and should not be copied into
   `~/.codex/skills`.
4. Prefer a user-provided or context-provided source path. For review branches
   and local test candidates, pass both `--source <kit-checkout>` and
   `--no-fetch`. If no local source exists, use the GitHub raw
   `operator-sync.sh` fallback.
5. Verify the install with status, summary, memory, roadmap, catalog, and lane
   recommendation checks.

Typical pinned local-source command:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh \
  --source /path/to/operator-kit \
  --target /path/to/project-root \
  --bootstrap-if-missing \
  --skip-skills \
  --no-fetch
```

Fallback command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh) \
  --target /path/to/project-root \
  --bootstrap-if-missing \
  --skip-skills
```

Do not install Operator Kit into the Operator Kit source checkout itself unless
the user explicitly targets that checkout as a project.

## Workflow

1. Inspect the project root and git status.
2. Identify default branch, package manager, and validation commands.
3. Propose or read a lane map.
4. In V2, initialize the system map, role catalog, architecture-pattern catalog, and lane recommendations.
5. Create an external operator workspace.
6. Install or update operator scripts, Operator Memory Router, local roadmap/feedback workspace, and evergreen docs.
7. Install Claude Code project assets under `.claude/` when the target project uses Claude Code.
8. Install Cursor project assets under `.cursor/` when the target project uses Cursor.
9. Create lane worktrees and branches.
10. Start tmux lanes.
11. Create a smoke task under the external operator workspace.
12. Verify `scripts/operator-memory.sh status`, `scripts/operator-roadmap.sh status`, `scripts/operator-catalog.sh list roles`, and `scripts/operator-recommend-lanes.sh`.
13. Dispatch and collect one smoke handoff when appropriate.
14. Report exact paths, branches, commands, V2 catalog/system-map status, memory/roadmap status, and validation status.

## V5.2 Distribution And Migration

Fresh `latest` installs use `OPERATOR_KIT_VERSION="5.2"`. Install the role map,
local graph shell/Python pair, V5.1 graph-migration command, and optional model
selector. Initialize the
catalog before deriving the target role map from `OPERATOR_LANES`. Do not
install or provision signing authorities, Keychain credentials, proof brokers,
trusted hosts, leases, fences, or heartbeat loops.

A plain latest update of V4 or signed V5 installs current tooling but preserves the
existing marker and reports migration required. Use
`operator-v5-1-migrate.sh plan`; apply only after review and explicit
`MIGRATE_TO_V5_1_LOCAL_GRAPH` authorization. Signed V5 authority, graph, host,
and loop directories move to a timestamped archive. Keychain entries are never
read, changed, or deleted.

V5.1 graphs are ordinary feature-scoped planning files. They advise which work
is dependency-ready and non-conflicting within a bounded capacity. They do not
dispatch work or replace human approval and operator integration review.

A healthy V5.1 local-graph project updates compatibly to V5.2. Model selection
remains off: bootstrap/update installs inert examples but no live catalog or
policy. During onboarding or migration, run `operator-model-select.sh
setup-guide`, ask the user for the models plus exact thinking settings they can
use, verified capabilities/context/data constraints, task-class outcome
estimates, policy floors and limits, and preferences or pins. Never request API
keys, enable `recommend`, or apply a recommendation implicitly.

## Agent-Run Setup

When the user wants an agent to fully set up the system from scratch, follow `docs/guides/agent-run-bootstrap.md` and the prompt template in `templates/prompts/agent-run-bootstrap.md`.

For an empty scoped project folder, first suggest this top-level layout:

```text
<project-root>/
  code/
    app/             canonical repo worktree
    app-backend/     optional permanent backend lane
    app-ui/          optional permanent UI lane
  operator/          tasks, handoffs, memory, roadmap, catalog
```

Use `<project-root>/code/<lane-worktree>` for permanent agent lanes and
`<project-root>/operator` for generated operator state. The operator should
also work when the chat is opened at `<project-root>` by resolving
`code/*/operator.config.env`.

The setup agent should inspect first, refresh the V2 system map and lane
recommendations, propose a lane map, install scripts/templates, create the
external operator workspace, create or verify worktrees, start tmux, run a smoke
task, and report whether the repo is ready to commit.

## V2 Catalog And Batch Planning

Installed V2 projects should include:

```bash
bash scripts/operator-catalog.sh list roles
bash scripts/operator-system-map.sh refresh
bash scripts/operator-recommend-lanes.sh
bash scripts/operator-plan-batch.sh
```

The catalog is the engineering-pattern source of truth for specialist roles,
approved packages/repos, validation recipes, and escalation gates. The batch
planner is advisory and requires operator approval before dispatch.

## Memory

Installed projects should include `scripts/operator-memory.sh` and
`OPERATOR_DIR/memory/`. Use task memory for feature-track facts, project memory
for durable cross-task facts, and `operator-dispatch.sh --with-memory` only
when retrieved context is relevant to the target lane.

## Roadmap And Feedback

Installed projects should include `scripts/operator-roadmap.sh`,
`scripts/operator-feedback.sh`, and `OPERATOR_DIR/roadmap/`. Keep local roadmap,
backlog, prioritization, raw feedback, screenshot/video annotations, and
planning views outside the app repo. Use PR/commit trace IDs for code-level
rationale.

For Codex Desktop daily use, keep the mode split explicit:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

## Operating Feature Tracks

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

Pause for user input before destructive cleanup, credential changes,
provider-console changes, production deploys, release submissions,
regulated, financial, or safety-critical behavior, or product decisions that
cannot be safely inferred.

## Guardrails

- Do not commit raw handoffs, pane captures, task packets, or task working files.
- Do not commit memory packs or generated operator memory.
- Do not rewrite git history.
- Do not let agents share branches.
- Do not let agents edit the same file at the same time.
- Keep project-specific secrets out of docs and examples.
- Do not treat the Operator workspace or signed-V5 migration archive as disposable.
