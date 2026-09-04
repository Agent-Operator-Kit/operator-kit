---
description: Enter Operator Kit sticky mode in this chat
---

Use the operator skill for this request.

1. Run `bash scripts/operator-status.sh` and `bash scripts/operator-context.sh` when available.
2. Default to **operator observe** unless I say `operator active` or `operator dispatch`.
3. Route status, blocked items, and lane summaries through Operator Kit scripts.
4. Do not implement large code changes in the operator chat; create task packets and dispatch lanes instead.
