# Cursor Adapter Package

This is a V3 host adapter package for Cursor. It is not a Codex-style plugin and
does not assume an unsupported Cursor runtime plugin API.

## Contents

```text
adapter.json
skills/                                  # copied from skills/cursor/
project-templates/.cursor/rules/         # copied from templates/cursor/rules/
project-templates/.cursor/skills/        # copied from templates/cursor/skills/
project-templates/.cursor/environment.json.example
prompts/cursor-agent-bootstrap.md
```

`skills/` contains the canonical Cursor skill source. The project templates
mirror the assets that `operator-sync.sh` installs into target repos.

## Install Model

Global adapter install can make these Cursor assets discoverable to a user or
distribution channel, but it must not bootstrap a project.

Project setup stays explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

Project refresh stays explicit:

```bash
bash scripts/operator-sync.sh --target /path/to/project
```

## Sticky Operator Mode

Cursor should expose sticky mode through rules, skills, prompts, or agent
instructions unless the host provides durable session state. Sticky mode means
default routing, not automatic execution: `operator observe` can answer status
and blocker questions, `operator active` can route feedback/planning/task
creation, and `operator dispatch` can execute only after explicit user intent
and preflight.

## Host Limitations

- Cursor rules and skills are project assets, not a hidden runtime state store.
- Cursor Cloud Agents are remote branch workers; include task packets and memory
  context directly in their prompts.
- Do not assume local tmux, local simulators, local `OPERATOR_DIR`, or local
  Operator Memory are available to Cursor Cloud Agents.
