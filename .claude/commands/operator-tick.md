---
description: Run one host-supervised Operator V5 tick for the bound top-level Claude session
argument-hint: --session SESSION --scope NODE [--max-actions N] [--dry-run]
---

Run the trusted host adapter for this top-level Claude Code session:

```bash
bash scripts/operator-host.sh tick --tool claude $ARGUMENTS
```

The graph lease and fence authorize mutation. This command does not grant a
Claude subagent independent lease, priority, gate, or integration authority.
Subagents and hooks may only return evidence to the bound top-level session or
ask that session to request another tick.
