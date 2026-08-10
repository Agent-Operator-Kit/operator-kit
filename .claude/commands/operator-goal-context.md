---
description: Emit durable Operator V5 goal context for the bound top-level Claude session
argument-hint: --session SESSION --scope NODE
---

Emit the graph-backed goal context for this top-level Claude Code session:

```bash
bash scripts/operator-host.sh goal-context --tool claude $ARGUMENTS
```

Treat the returned objective as prompt context only. The graph remains the
source of truth, and subagents do not inherit mutation or integration authority.
