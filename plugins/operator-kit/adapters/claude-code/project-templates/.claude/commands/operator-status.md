---
description: Inspect Agent Operator Kit status for this repo
---

Inspect the Agent Operator Kit status for this repo.

Run:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
git status --short --branch
```

Summarize:

- lane health
- dirty worktrees
- branch drift
- tmux availability
- latest handoffs
- memory status
- next recommended operator action

Do not make file edits unless explicitly asked.
