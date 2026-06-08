# V3 Host Adapters

This folder packages host-specific global adapter metadata for Agent Operator
Kit V3.

```text
adapters/
  cursor/
    adapter.json
    skills/
    project-templates/.cursor/
    prompts/
  claude-code/
    adapter.json
    skills/
    project-templates/.claude/
```

Codex is the only true plugin package in this repository slice. Cursor and
Claude Code packages are adapter bundles: they collect skills, rules, commands,
agents, setup prompts, and compatibility metadata without assuming unsupported
runtime plugin APIs.

Installing any global adapter does not create project-local Operator Kit state.
Project setup remains explicit through `operator-sync.sh`, `operator-upgrade.sh`,
or installed project-local `scripts/operator-*.sh`.
