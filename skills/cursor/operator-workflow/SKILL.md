# Cursor Operator Workflow Skill

Use this skill when setting up or operating Agent Operator Kit from Cursor IDE, Cursor CLI, or Cursor Cloud Agents.

Cursor integration has three layers:

- `.cursor/rules/operator-workflow.mdc` for persistent project guidance.
- `.cursor/skills/operator-workflow/SKILL.md` for procedural setup and operations.
- `.cursor/environment.json.example` as a starting point for Cloud Agent environments.

Operator Kit integrates with whichever coding agents are available. When Cursor
is available, Cursor IDE makes a natural operator cockpit; when Codex Desktop
is available, Codex `$operator-*` skills can be the cockpit instead; Claude
Code can fill UI or scoped lanes regardless. Pick the cockpit per project and
fill remaining lanes from the agents you have.

In environments without Codex, prefer a Cursor IDE operator lane, a Cursor CLI
worker lane, and Claude Code lanes only where Claude is available.

## Cursor Primitives

- Rules are persistent project instructions. Keep lane boundaries, external
  state policy, and safety guardrails in `.cursor/rules/*.mdc`.
- Skills are reusable procedures. Use `operator` for execution,
  `operator-planner` for planning, `operator-feedback` for feedback intake,
  `design-agent` for UX/design work, UX Auditor (`ux-auditor`) for scored UX audits,
  `user-journey` for journey artifacts, `incubation` for lightweight idea work,
  and `operator-workflow` for setup, repair, and upgrade workflows.
- Prompt templates are copy/paste entry points for bootstrapping or Background
  Agent tasks. They live under `templates/prompts/` in the kit source.
- Cursor CLI is a local terminal agent surface. Some installs expose it as
  `cursor agent`; others provide `cursor-agent`.
- Cursor Cloud Agents, formerly Background Agents, are remote branch workers. They cannot rely on local
  tmux sessions, simulators, or `OPERATOR_DIR`.

## Local Cursor Operator

Use Cursor IDE Agent or Cursor CLI when Cursor should operate the local worktrees and tmux lanes.

For first-time or repeat setup, prefer install-or-initialize behavior:

1. Inspect the repo and git status.
2. Detect install state:
   - installed: `operator.config.env` exists and `scripts/operator-status.sh`
     runs;
   - partial: some Operator Kit files exist but required scripts/config are
     missing or status fails;
   - missing: no reliable Operator Kit files exist.
3. If installed, refresh with `scripts/operator-sync.sh` from the installed
   project or source kit.
4. If partial, repair from the source kit while preserving `operator.config.env`,
   `OPERATOR_DIR`, handoffs, tasks, memory, roadmap, docs, and source code.
5. If missing, install with `operator-sync.sh --bootstrap-if-missing
   --bootstrap-profile cursor --skip-skills`.
6. Initialize or refresh the V2 system map and catalog:
   - `bash scripts/operator-system-map.sh refresh`
   - `bash scripts/operator-recommend-lanes.sh`
   - `bash scripts/operator-catalog.sh list roles`
7. Convert user-supplied lane requirements into `operator.config.env`; if lanes
   are unclear, propose the lane map before creating worktrees.

The local flow:

1. Inspect the repo and git status.
2. Read `operator.config.env`.
3. Confirm lane map and expected branches.
4. Keep generated state under `OPERATOR_DIR`.
5. Use `scripts/operator-task.sh`, `scripts/operator-dispatch.sh`, `scripts/operator-collect.sh`, `scripts/operator-summary.sh`, `scripts/operator-memory.sh`, `scripts/operator-roadmap.sh`, `scripts/operator-feedback.sh`, `scripts/operator-catalog.sh`, `scripts/operator-system-map.sh`, `scripts/operator-recommend-lanes.sh`, and `scripts/operator-plan-batch.sh`.
6. Commit only evergreen repo changes.

For first-time setup without Codex, use the Cursor bootstrap profile:

```bash
bash scripts/operator-bootstrap.sh --profile cursor /path/to/repo
```

or:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

Review the generated `operator.config.env` before running `operator-tmux.sh
start-workers`. Choose the GPT-5.5 model through Cursor's configured model
picker or company policy; do not hard-code model flags unless the local Cursor
CLI documents and supports them.

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

## Cursor CLI

Cursor CLI uses `cursor agent` or `cursor-agent`, depending on how the CLI is
installed.

Useful commands:

```bash
cursor agent
cursor agent "Set up Agent Operator Kit for this repo"
cursor-agent "Set up Agent Operator Kit for this repo"
```

Use non-interactive mode carefully because it can have write access depending on flags and configuration.

## Cursor Cloud Agents

Cloud Agents run remotely, clone from GitHub, work on a separate branch, and push back to the repo.

Use them for isolated branch work. Do not assume access to local tmux sessions, local simulators, or local `OPERATOR_DIR`.

For every Cloud Agent prompt, include:

- branch name
- task scope
- read-only areas
- validation commands
- handoff requirements

Do not assume Cloud Agents can access local Operator Memory. Include the
relevant context explicitly in the prompt or task packet.

## Memory

Local Cursor operator work can use `operator-dispatch.sh --with-memory` to add
a compact context pack. Use project memory for durable facts and task memory for
feature-track facts. Do not commit generated memory files.

## Roadmap And Feedback

Keep local roadmap, backlog, feedback intake, and planning views under
`OPERATOR_DIR/roadmap/`. Do not commit raw feedback annotations or local planning
views into the app repo; use PR/commit trace references instead.

For Codex Desktop projects, use `$operator-feedback` for intake,
`$operator-planner` for planning, and `$operator` for execution.

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets.
- Do not commit raw handoffs, task packets, pane captures, task working files, or transient notes.
- Do not commit memory packs or generated operator memory.
- Do not start deployments or production builds during setup.
- Ask before destructive cleanup, credential/provider-console changes,
  production deploys, release submissions, live-money enablement, or product
  decisions that cannot be safely inferred.
