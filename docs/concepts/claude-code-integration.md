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

## Sticky Operator Mode In Claude Code

Claude Code should expose sticky Operator behavior through slash commands,
project agents, and project documentation rather than a separate runtime. Once a
Claude Code session is bound to an Operator project, natural project-control
phrases can follow the sticky routing contract.

Sticky routing is not automatic execution. Status, feedback, planning, and task
creation can become easier to invoke, but dispatch, collection, source
integration, push, tag, destructive cleanup, provider changes, and credential
changes still require explicit intent and the same Operator safety gates. See
[Sticky Operator mode](sticky-operator-mode.md).

References:

- Claude Code slash commands: https://docs.anthropic.com/en/docs/claude-code/slash-commands
- Claude Code subagents: https://docs.anthropic.com/en/docs/claude-code/sub-agents
