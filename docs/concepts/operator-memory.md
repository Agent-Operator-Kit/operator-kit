# Operator Memory Router

Operator Memory Router is the pragmatic memory layer for Agent Operator Kit. It
exists to carry relevant context across lanes, tasks, and compacted chat
sessions without turning every agent invocation into a giant shared prompt.

## Why This Model

Claude Code documents a fresh context window per session and uses project
memory files plus auto memory to carry knowledge across sessions. `AGENTS.md`
uses the same basic idea for coding agents: predictable project instructions.
OpenClaw and Agent OS push further toward an agent operating system with
persistent agent memory, state, and routing.

Operator Kit takes the narrower path: keep source-of-truth instructions in the
repo, keep generated operational memory outside the repo, retrieve only the
pieces relevant to the current lane and task, and require explicit promotion
for facts that should become durable.

References:

- [Claude Code memory](https://code.claude.com/docs/en/memory)
- [AGENTS.md format](https://github.com/agentsmd/agents.md)
- [OpenClaw workspace files](https://github.com/openclaw/openclaw)
- [OpenClaw Agent OS](https://openclawlaunch.com/skills/agent-os)

## Memory Layers

```text
AGENTS.md
  Evergreen repo operating rules, committed with source.

OPERATOR_DIR/memory/project.md
  Durable project facts, decisions, constraints, and recurring pitfalls.

OPERATOR_DIR/tasks/<slug>/memory.md
  Feature-track memory shared by all lanes working on the same task.

OPERATOR_DIR/memory/episodes/*.md
  Distilled lane handoffs generated from collection.

OPERATOR_DIR/memory/packs/
  Optional generated context packs for inspection or replay.
```

Raw pane captures and task handoffs are evidence. They are not memory by
themselves. Promote only concise facts that should influence future dispatches.

## Commands

```bash
bash scripts/operator-memory.sh init
bash scripts/operator-memory.sh status
bash scripts/operator-memory.sh search "billing retry"
bash scripts/operator-memory.sh promote project "Use the disposable e2e profile for Playwright validation."
bash scripts/operator-memory.sh promote task checkout-001 "The UI lane owns src/app/checkout/* for this feature."
bash scripts/operator-memory.sh pack backend checkout-001 --task-file "$OPERATOR_DIR/tasks/checkout-001/tasks/backend.md"
```

Use memory on dispatch when previous lane context matters:

```bash
bash scripts/operator-dispatch.sh --with-memory backend "$OPERATOR_DIR/tasks/checkout-001/tasks/backend.md"
```

Collection automatically creates an episode file:

```bash
bash scripts/operator-collect.sh backend checkout-001
```

## Promotion Rules

Promote to project memory when the fact will help many future tasks: local data
profiles, recurring validation commands, architectural constraints, team
decisions, or repeated failure modes.

Promote to task memory when the fact matters only to the current feature track:
lane ownership, cross-lane API contracts, validated approaches, rejected
approaches, blockers, or follow-up routing.

Move a fact from operator memory into committed repo docs only when it should be
shared with every contributor and agent by default.

## Handoff Contract

Every lane handoff should include a `## Memory Candidates` section with only
items worth considering for future retrieval:

- durable decision
- project fact
- task constraint
- failed approach
- validation finding
- follow-up needed from another lane

The operator reviews those candidates. Nothing becomes durable project or task
memory unless it is promoted intentionally.
