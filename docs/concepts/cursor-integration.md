# Cursor Integration

Cursor can be used as a frontend operator surface for Agent Operator Kit.

There are three useful Cursor modes:

1. Cursor IDE Agent as the operator UI.
2. Cursor CLI with `cursor-agent` as a local worker or operator assistant.
3. Cursor Background Agents as remote GitHub-branch workers.

## Local Cursor Operator

Use Cursor IDE or Cursor CLI when you want Cursor to operate the same local worktrees and tmux session as Codex and Claude Code.

In this mode, Cursor should:

- read `AGENTS.md`, `CODEX.md`, `CLAUDE.md`, and `.cursor/rules`
- use `operator.config.env` as the lane map
- keep generated task packets, handoffs, and task working files under `OPERATOR_DIR`
- start or inspect tmux with `scripts/operator-tmux.sh`
- avoid committing raw handoffs, task packets, or task working files

This mode fits the standard Agent Operator Kit model best.

## Cursor Background Agents

Cursor Background Agents run asynchronously in remote isolated machines. They clone the repo from GitHub, work on a separate branch, and push back to the repo.

Use Background Agents for self-contained branch tasks such as:

- UI polish
- isolated bug fixes
- documentation cleanup
- test additions
- small refactors with clear boundaries

Do not depend on the local `OPERATOR_DIR` in a Background Agent. Instead, put the task packet in the prompt and require the agent to return a handoff in its final response, branch commits, or pull request description.

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

The rule gives Cursor persistent project guidance. The skill is the procedural setup and operations playbook. The environment example is a starting point for Background Agents and should be adapted per project before being renamed to `.cursor/environment.json`.

## References

- Cursor Agent modes: https://docs.cursor.com/agent
- Cursor project rules: https://docs.cursor.com/context/rules
- Cursor CLI: https://docs.cursor.com/en/cli
- Cursor CLI usage: https://docs.cursor.com/en/cli/using
- Cursor Background Agents: https://docs.cursor.com/en/background-agents
