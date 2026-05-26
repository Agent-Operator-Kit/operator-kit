# Cursor Operator Workflow

Use this guide when Cursor is the primary operator IDE for an Agent Operator Kit
project.

Operator Kit is an operating layer that integrates with the coding surfaces you
have. When Cursor is available, Cursor Composer or Agent makes a natural
operator cockpit; when Codex is available, Codex Desktop can be the cockpit
instead; when both are available, pick per project. The lane map, task packets,
worktrees, tmux sessions, feedback intake, roadmap promotion, memory router,
handoffs, and integration review stay the same regardless of which IDE owns the
operator role.

This guide focuses on the Cursor cockpit setup.

## Cursor-First Shape

For teams without Codex, bootstrap with the Cursor profile:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

or:

```bash
bash scripts/operator-bootstrap.sh --profile cursor /path/to/repo
```

The generated lane map starts with:

```text
operator|Cursor IDE|app|main|
cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
```

Review `operator.config.env` before creating worktrees or starting workers. Some
machines expose the local agent as `cursor agent`; others provide
`cursor-agent`.

## Cursor Primitives

- `AGENTS.md` carries portable baseline instructions for all agents.
- `.cursor/rules/*.mdc` carries persistent Cursor project policy.
- `.cursor/skills/*/SKILL.md` carries reusable operator procedures.
- `.cursor/agents/*.md` can define specialist subagents for review, research,
  validation, debugging, and release checks.
- Cursor CLI can run in a tmux lane for durable local work.
- Cursor Cloud Agents, formerly Background Agents, are remote branch workers and do not share local
  `OPERATOR_DIR`, tmux, or simulators.

Treat subagents as temporary specialist contexts. Treat operator lanes as
durable worktree, branch, and process boundaries.

## Local Operating Loop

Start from the operator lane in Cursor:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-roadmap.sh status
```

Create task state outside the repo:

```bash
bash scripts/operator-task.sh auth-001 "Auth scaffolding"
```

Write lane-specific task packets under:

```text
OPERATOR_DIR/tasks/auth-001/tasks/
```

Dispatch to a local tmux lane when appropriate:

```bash
bash scripts/operator-dispatch.sh --with-memory cursor "$OPERATOR_DIR/tasks/auth-001/tasks/cursor.md"
```

Collect the result as an external handoff:

```bash
bash scripts/operator-collect.sh cursor auth-001
```

Then review the worker branch from Cursor, run validation, and integrate only
approved source changes into the stable branch.

## Feedback To Execution

Cursor-first projects use the same script-backed mode split as Codex projects:

```text
Feedback   -> bash scripts/operator-feedback.sh ...
Planning   -> bash scripts/operator-roadmap.sh ...
Execution  -> bash scripts/operator-task.sh / dispatch / collect / summary
```

Feedback is observation. Planning decides what becomes work. Execution starts
only after the operator has a scoped task packet and lane ownership.

## Cloud Agents

Use Cursor Cloud Agents for isolated remote branch work: documentation cleanup,
small refactors, focused bug fixes, and tests. Do not assume they can see local
operator state. Put the task packet, relevant memory, validation commands, and
handoff requirements directly in the prompt or PR description.

Use `.cursor/environment.json.example` as the starting point for Cloud Agent
setup, then adapt it to the target project before saving `.cursor/environment.json`.

## Model Selection

Choose GPT-5.5 or another Cursor model through Cursor's configured model picker,
CLI support, or company policy. Do not hard-code model flags in the lane map
unless the local Cursor CLI documents and supports them.

## Upgrade

Cursor-only machines can skip Codex Desktop skill refresh:

```bash
bash scripts/operator-upgrade.sh --skip-skills
```

For one project:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --skip-skills
```
