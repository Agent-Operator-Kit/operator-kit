# Operator Workspace

This directory stores local operator state for Agent Operator Kit.

Layout:

```text
tasks/<slug>/00-operator-brief.md
tasks/<slug>/memory.md
tasks/<slug>/tasks/*.md
tasks/<slug>/handoffs/*.md
captures/
memory/project.md
memory/episodes/*.md
memory/packs/
```

This directory is outside the repo by design. It is safe to delete and recreate unless you intentionally keep local task history.

Use `memory/project.md` for durable project facts and `tasks/<slug>/memory.md` for feature-track facts that should move across lanes. Episode files are distilled from collected handoffs.

Do not push raw handoffs, task packets, pane captures, memory packs, or transient notes to the project repository.
