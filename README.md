# Agent Operator Kit

Agent Operator Kit is a lightweight operating model for coordinating coding agents across isolated git worktrees using tmux, external task handoffs, and an operator-owned integration flow.

It is designed for teams or solo builders who want Codex, Claude Code, and similar agents to work in parallel without polluting the codebase with transient task packets, raw handoffs, pane captures, or session notes.

## Core Idea

- One human or primary agent acts as the operator and integrator.
- Worker agents run in named lanes such as `backend`, `ui`, `release`, or `product`.
- Each lane has its own git worktree and branch.
- tmux keeps long-running agents visible and recoverable.
- Task packets and handoffs live outside the repo in an operator workspace.
- The repo keeps only evergreen docs, reusable scripts, and source code.

## Layout

Recommended project layout:

```text
~/Projects/acme/
  code/
    app/              # canonical repo worktree
    app-backend/      # optional worker worktree
    app-ui/           # optional worker worktree
  operator/
    README.md
    tasks/
      <slug>/
        00-operator-brief.md
        tasks/*.md
        handoffs/*.md
    captures/
```

Recommended repo layout after installation:

```text
.cursor/
  rules/
    operator-workflow.mdc
  skills/
    operator-workflow/
      SKILL.md
  environment.json.example
.claude/
  commands/
    operator-bootstrap.md
    operator-status.md
  agents/
    operator-workflow.md
scripts/
  operator-lib.sh
  operator-tmux.sh
  operator-status.sh
  operator-task.sh
  operator-dispatch.sh
  operator-collect.sh
  operator-summary.sh

AGENTS.md
operator.config.env
```

## Getting Started With Codex Or Claude Code

Agent Operator Kit is optimized for agent-run setup. Ask Codex, Claude Code, or Cursor to do the setup for you with:

```text
Use git@github.com:Agent-Operator-Kit/operator-kit.git to set up Agent Operator Kit for this project. Follow the agent-run bootstrap guide and keep generated task/handoff state outside the repo.
```

Full copy/paste prompt:

```text
templates/prompts/agent-run-bootstrap.md
```

Getting started guide:

```text
docs/guides/getting-started-with-agents.md
```

Full bootstrap guide:

```text
docs/guides/agent-run-bootstrap.md
```

Codex-specific reusable guidance:

```text
skills/codex/operator-workflow/SKILL.md
```

Claude Code reusable assets:

```text
templates/claude/commands/operator-bootstrap.md
templates/claude/commands/operator-status.md
templates/claude/agents/operator-workflow.md
skills/claude-code/operator-workflow/SKILL.md
```

Cursor reusable assets:

```text
templates/cursor/rules/operator-workflow.mdc
templates/cursor/skills/operator-workflow/SKILL.md
templates/cursor/environment.json.example
templates/prompts/cursor-agent-bootstrap.md
skills/cursor/operator-workflow/SKILL.md
```

For an existing project:

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git
cd operator-kit
bash scripts/operator-bootstrap.sh /path/to/your/repo
```

Then from the target repo:

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-status.sh
bash scripts/operator-task.sh setup-smoke-001 "Setup smoke"
```

## Configuration

The generated `operator.config.env` file is plain shell configuration so agents can inspect and edit it without extra tooling.

Example:

```bash
PROJECT_NAME="acme"
PROJECT_ROOT="$HOME/Projects/acme"
CODE_DIR="$PROJECT_ROOT/code"
OPERATOR_DIR="$PROJECT_ROOT/operator"
TMUX_SESSION="acme"
DEFAULT_BRANCH="main"

OPERATOR_LANES='
operator|Codex Desktop|app|main|
backend|Codex CLI|app-backend|codex/backend|codex --dangerously-bypass-approvals-and-sandbox
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
'
```

Lane format:

```text
lane_id|owner|worktree_directory|branch|agent_invocation
```

## Commands

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-tmux.sh attach
bash scripts/operator-tmux.sh start-workers
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--no-enter] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
```

## Rules

- Do not let two agents share the same branch.
- Do not let two agents edit the same file at the same time.
- Do not merge worker branches into `main` without operator review.
- Do not commit raw handoffs, task packets, pane captures, or transient session notes.
- Keep generated operator state under `OPERATOR_DIR`.
- Distill durable facts into evergreen repo docs.

## Status

This is an initial public version. The shell scripts are intentionally small and inspectable. A richer CLI can wrap the same model later.
