# Claude Code Integration

Claude Code supports project-level reusable prompts as Markdown slash commands under `.claude/commands/`, and specialized project subagents as Markdown files with YAML frontmatter under `.claude/agents/`.

Agent Operator Kit uses those mechanisms for Claude Code rather than inventing a separate runtime:

```text
.claude/
  commands/
    operator-bootstrap.md
    operator-status.md
  agents/
    operator-workflow.md
```

The slash commands are for explicit user invocation. The subagent is for delegating operator setup, status inspection, and workflow maintenance to a specialized Claude Code context.

References:

- Claude Code slash commands: https://docs.anthropic.com/en/docs/claude-code/slash-commands
- Claude Code subagents: https://docs.anthropic.com/en/docs/claude-code/sub-agents
