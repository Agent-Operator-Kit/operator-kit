# Cursor Integration

Cursor can be the primary operator surface for Agent Operator Kit, including in
environments where Codex is unavailable. In that model, Cursor IDE owns local
operator review and integration, Cursor CLI can run a local worker lane, and
Claude Code can remain a scoped UI or implementation worker when available.

There are three useful Cursor execution surfaces:

1. Cursor IDE Agent as the operator UI.
2. Cursor CLI with `cursor agent` / `cursor-agent` as a local worker or operator assistant.
3. Cursor Cloud Agents, formerly Background Agents, as remote GitHub-branch workers.

## Composer Versus Operator Kit

Cursor Composer and Agent are interactive coding surfaces. Codex Desktop and
Claude Code are also interactive coding surfaces. Operator Kit is the operating
layer around any of them.

```text
Coding surface (Cursor / Codex / Claude / etc.)
  Edits, explores, debugs, reviews, and delegates from the current workspace.

Operator Kit
  Defines lanes, task packets, worktrees, tmux sessions, feedback intake,
  roadmap promotion, memory routing, handoffs, and integration review.
```

Operator Kit integrates with whatever stack is available:

- Cursor available, Codex unavailable: Cursor Composer is the operator cockpit;
  Cursor CLI runs a local worker lane; Claude Code can fill UI or scoped lanes.
- Codex available: Codex Desktop `$operator-*` skills can be the cockpit; Codex
  CLI fills backend or release lanes; Cursor and Claude can still appear as
  worker lanes.
- Both available: pick the operator cockpit per project. Worker lanes can mix
  Codex CLI, Cursor CLI, and Claude Code.

The kit stays the same in every case: external `OPERATOR_DIR`, lane map in
`operator.config.env`, scripts under `scripts/`, and the memory router. The
goal is not to replace your IDE; the goal is to keep that IDE focused by
retrieving only the relevant operator state for the current lane and task.

## Cursor Primitives

Cursor project rules, skills, command prompts, and agents serve different
purposes:

```text
.cursor/rules/*.mdc
  Persistent project guidance. Use for always-on lane rules, external state
  policy, and guardrails that every Cursor Agent session should see.

.cursor/skills/<name>/SKILL.md
  Procedural playbooks. Use for setup, repair, status checks, dispatch,
  collection, and repeatable operator workflows.

Prompt templates
  Copy/paste entry points for a new setup run or a Cloud Agent task.
  Operator Kit keeps these under templates/prompts/.

Cursor CLI / cursor agent
  A terminal agent surface that can run as a local lane under tmux, subject to
  the installed Cursor CLI and organization model policy.

Cursor Cloud Agents
  Remote branch workers. They do not share local tmux, local simulators, or
  OPERATOR_DIR, so prompts must include the full task packet and handoff rules.
```

## Local Cursor Operator

Use Cursor IDE or Cursor CLI when you want Cursor to operate the same local worktrees and tmux session as other local agents.

In this mode, Cursor should:

- read `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, and `operator.config.env`
- use `operator.config.env` as the lane map
- keep generated task packets, handoffs, and task working files under `OPERATOR_DIR`
- start or inspect tmux with `scripts/operator-tmux.sh`
- avoid committing raw handoffs, task packets, or task working files

This mode fits the standard Agent Operator Kit model best.

For Cursor-first projects without Codex, bootstrap with:

```bash
bash scripts/operator-bootstrap.sh --profile cursor /path/to/repo
```

or through sync:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

The Cursor profile generates a lane map like:

```text
operator|Cursor IDE|app|main|
cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
```

Edit the lane names, branches, and invocations before starting workers. Some
Cursor CLI installations expose `cursor agent` through the `cursor` command
first and install a `cursor-agent` helper on demand. Use whichever command your
machine or company image supports.

## Cursor Cloud Agents

Cursor Cloud Agents, formerly Background Agents, run asynchronously in remote
isolated machines. They clone the repo from GitHub, work on a separate branch,
and push back to the repo.

Use Cloud Agents for self-contained branch tasks such as:

- UI polish
- isolated bug fixes
- documentation cleanup
- test additions
- small refactors with clear boundaries

Do not depend on the local `OPERATOR_DIR` in a Cloud Agent. Instead, put
the task packet, relevant memory, validation commands, and handoff requirements
in the prompt. Require the agent to return a handoff in its final response,
branch commits, or pull request description.

## Cursor Project Assets

Agent Operator Kit installs these project assets:

```text
.cursor/
  rules/
    operator-workflow.mdc
  skills/
    operator-workflow/
      SKILL.md
  environment.json.example
```

The rule gives Cursor persistent project guidance. The skill is the procedural setup and operations playbook. The environment example is a starting point for Cloud Agents and should be adapted per project before being renamed to `.cursor/environment.json`.

## References

- Cursor Agent modes: https://docs.cursor.com/agent
- Cursor project rules: https://docs.cursor.com/context/rules
- Cursor CLI: https://docs.cursor.com/en/cli
- Cursor CLI usage: https://docs.cursor.com/en/cli/using
- Cursor Cloud Agents: https://docs.cursor.com/cloud-agent
