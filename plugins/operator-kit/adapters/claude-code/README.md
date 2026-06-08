# Claude Code Adapter Package

This is a V3 host adapter package for Claude Code. It packages Operator Kit
workflow docs, slash-command templates, and project subagent templates without
inventing a hidden runtime plugin API.

## Contents

```text
adapter.json
skills/                                  # copied from skills/claude-code/
project-templates/.claude/commands/      # copied from templates/claude/commands/
project-templates/.claude/agents/        # copied from templates/claude/agents/
```

## Install Model

Global adapter install can make the Claude Code workflow package discoverable,
but it must not bootstrap a project.

Project setup stays explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing
```

Project refresh stays explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project
```

## Host Limitations

- Slash commands and subagents are explicit project assets under `.claude/`.
- The adapter package does not create `operator.config.env`, `OPERATOR_DIR`, or
  lane worktrees by itself.
- Claude Code lanes use the same Operator Kit task packet, handoff, memory, and
  roadmap model as Codex and Cursor lanes.
