# Operator Workspace

This directory stores local operator state for Agent Operator Kit.

Layout:

```text
tasks/<slug>/00-operator-brief.md
tasks/<slug>/tasks/*.md
tasks/<slug>/handoffs/*.md
captures/
```

This directory is outside the repo by design. It is safe to delete and recreate unless you intentionally keep local task history.

Do not push raw handoffs, task packets, pane captures, or transient notes to the project repository.
