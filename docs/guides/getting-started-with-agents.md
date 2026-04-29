# Getting Started With Codex, Claude Code, Or Cursor

Agent Operator Kit is intended to be installed by an agent, not by a human following a long checklist.

Use this page when you want to open a fresh Codex, Claude Code, or Cursor session and ask it to set up the operator workflow end to end.

## Codex

Start Codex in or near the target repo and paste:

```text
Set up Agent Operator Kit for this project using:
git@github.com:Agent-Operator-Kit/operator-kit.git

Use the agent-run bootstrap flow. Inspect first, propose the lane map, install the scripts/templates, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

Keep generated task packets, handoffs, pane captures, and transient notes outside the repo.
```

For the full prompt, use:

```text
templates/prompts/agent-run-bootstrap.md
```

For Codex skill-style guidance, use:

```text
skills/codex/operator-workflow/SKILL.md
```

## Claude Code

Start Claude Code in or near the target repo and paste:

```text
Set up Agent Operator Kit for this project using:
git@github.com:Agent-Operator-Kit/operator-kit.git

Use the agent-run bootstrap flow. Inspect first, propose the lane map, install the scripts/templates, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

Install the Claude Code project assets too:
- .claude/commands/operator-bootstrap.md
- .claude/commands/operator-status.md
- .claude/agents/operator-workflow.md

Keep generated task packets, handoffs, pane captures, and transient notes outside the repo.
```

For Claude Code, the reusable assets are project slash commands and a project subagent. Agent Operator Kit stores those as templates so bootstrap can install them into the target repo.

After installation, Claude Code users can run:

```text
/operator-status
```

or:

```text
/operator-bootstrap <absolute path to repo>
```

They can also explicitly invoke the project subagent:

```text
Use the operator-workflow subagent to inspect this repo and set up Agent Operator Kit.
```

## Cursor

Start Cursor Agent or Cursor CLI in or near the target repo and paste:

```text
Set up Agent Operator Kit for this project using:
git@github.com:Agent-Operator-Kit/operator-kit.git

Use Cursor as the frontend operator surface. Inspect first, propose the lane map, install the scripts/templates, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

Install the Cursor project assets too:
- .cursor/rules/operator-workflow.mdc
- .cursor/skills/operator-workflow/SKILL.md
- .cursor/environment.json.example

Keep generated task packets, handoffs, pane captures, and transient notes outside the repo.
```

For the full Cursor prompt, use:

```text
templates/prompts/cursor-agent-bootstrap.md
```

After installation, Cursor uses:

```text
.cursor/rules/operator-workflow.mdc
.cursor/skills/operator-workflow/SKILL.md
```

Cursor Background Agents should be treated as remote branch workers. Put the full task packet in the Background Agent prompt and require the final response or PR description to include the handoff.

## What The Agent Should Return

The setup agent should finish with:

- installed files
- `OPERATOR_DIR`
- lane map
- tmux session name
- smoke task path
- validation results
- repo `git status`
- whether the repo is ready to commit

It should not make deployments, production builds, provider-console changes, force-pushes, or destructive git operations during setup.
