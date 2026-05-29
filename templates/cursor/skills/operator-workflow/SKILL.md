---
name: operator-workflow
description: Use when setting up or operating Agent Operator Kit, tmux lanes, git worktrees, external task packets, handoffs, Cursor Cloud Agents, or status summaries.
---

# Operator Workflow

Use this skill to install, maintain, or operate Agent Operator Kit from Cursor.

Operator Kit integrates with whichever coding agents are available. When Cursor
is available, Cursor IDE makes a natural operator cockpit; when Codex Desktop
is available, Codex `$operator-*` skills can be the cockpit instead; Claude
Code can fill UI or scoped lanes regardless. Pick the cockpit per project and
fill remaining lanes from the agents you have.

## Cursor Primitives

- Rules are persistent project instructions. Keep lane boundaries, external
  state policy, and safety guardrails in `.cursor/rules/*.mdc`.
- Skills are reusable procedures. Use `operator` for execution,
  `operator-planner` for planning, `operator-feedback` for feedback intake,
  `design-agent` for UX/design work, `ux-auditor` for scored UX audits,
  `user-journey` for journey artifacts, `incubation` for lightweight idea work,
  and `operator-workflow` for setup, repair, and upgrade workflows.
- Prompt templates are copy/paste entry points for bootstrapping or Background
  Agent tasks. Operator Kit keeps these under `templates/prompts/`.
- Cursor CLI is a local terminal agent surface. Some installs expose it as
  `cursor agent`; others provide `cursor-agent`.
- Cursor Cloud Agents, formerly Background Agents, are remote branch workers. They cannot rely on local
  tmux sessions, simulators, or `OPERATOR_DIR`.

## Local Cursor Operator Flow

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
6. Convert user-supplied lane requirements into `operator.config.env`; if lanes
   are unclear, propose the lane map before creating worktrees.
7. Read `AGENTS.md`, `operator.config.env`, and `.cursor/rules/operator-workflow.mdc`.
8. Confirm the stable branch and lane map.
9. Ensure `OPERATOR_DIR` is outside the repo.
10. Create or verify lane worktrees.
11. Start or inspect tmux.
12. Create a smoke task under `OPERATOR_DIR`.
13. Run:
   - `bash -n scripts/*.sh`
   - `bash scripts/operator-status.sh`
   - `bash scripts/operator-summary.sh`
   - `bash scripts/operator-memory.sh status`
   - `bash scripts/operator-roadmap.sh status`
14. Report installed files, lane map, smoke results, memory/roadmap status, dirty files, and whether the repo is ready to commit.

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

## Cursor Cloud Agent Flow

Cursor Cloud Agents run remotely and push a separate branch to GitHub. Do not assume they can access the local `OPERATOR_DIR` or local Operator Memory.

For Cloud Agent tasks:

1. Put the full task packet in the prompt.
2. Include branch name, scope, read-only areas, validation commands, and handoff requirements.
3. Require a final handoff that names changed files, commands run, tests, blockers, and follow-up needs.
4. Do not use Cloud Agents for provider-console changes, production deploys, or tasks that require local device/simulator state unless the environment is explicitly configured.
5. Include relevant operator memory explicitly in the prompt when a Cloud Agent needs it.

## Memory

Use `scripts/operator-memory.sh` for local cross-lane context. Dispatch with
`--with-memory` when a lane needs retrieved context. Promote concise project or
task facts; do not commit generated memory files.

## Roadmap And Feedback

Use `scripts/operator-roadmap.sh` and `scripts/operator-feedback.sh` for local
roadmap, backlog, feedback intake, and screenshot/video annotation workflows.
Keep this state under `OPERATOR_DIR`, not in the app repo.

For Codex Desktop projects, use `$operator-feedback` for intake,
`$operator-planner` for planning, and `$operator` for execution.

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets.
- Do not commit raw handoffs, task packets, pane captures, task working files, or transient notes.
- Do not commit memory packs or generated operator memory.
- Do not start production builds, deployments, or provider-console changes during setup.
- Ask before destructive commands.
- Ask before credential/provider-console changes, release submissions,
  live-money enablement, or product decisions that cannot be safely inferred.
