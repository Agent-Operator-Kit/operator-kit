---
description: Restore one durable Operator V5 graph scope for this top-level Claude session
argument-hint: --session SESSION --scope NODE
---

Open the durable host binding for this top-level Claude Code session:

```bash
bash scripts/operator-host.sh open --tool claude $ARGUMENTS
```

The returned graph node, actor binding, lane, branch, worktree, and handoff
directory are authoritative host context. Do not infer authority from the chat
title or copy another session's binding. Claude subagents may report evidence
to this top-level session, but they must not bind, lease, prioritize, integrate,
decide gates, or cross graph scope.
