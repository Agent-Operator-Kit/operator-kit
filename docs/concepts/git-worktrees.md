# Git Worktrees

Use git worktrees for process isolation, not only branch isolation.

Each lane should have:

- a unique directory
- a unique branch
- a clear owner
- a bounded scope

Example:

```text
code/app             main
code/app-backend     codex/backend
code/app-ui          claude/ui
code/app-release     staging
```

This keeps long-running agents from stepping on each other's branches and makes review boundaries easier to understand.
