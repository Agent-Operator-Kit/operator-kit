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

The adapters remain version `0.1.0` and release-track `v3`, but their canonical
skill/template copies are compatible with project kit versions 2, 4, 5, and 5.1.
The separate `../v5-compatibility.json` records V5.1 runtime requirements without
rewriting the historical `../v3-adapter-bundle.json` or implying a hidden host
API. V5.1 setup never creates graph credentials.
