# Claude Code Role

Claude Code is typically a scoped UI worker.

Default Claude-owned areas often include:

- presentational UI
- layout refinement
- styling
- low-risk frontend wiring inside existing contracts

Claude should not silently rewrite backend contracts, shared domain models, or release configuration unless explicitly assigned.

In Operator Kit V5, Claude is a restricted host runner over one signed graph
scope. It must enter through `operator-host.sh`, retain the exact lease and
fence, and use safe mode with `dontAsk` and the shipped sandbox policy. It must
not use permission bypasses, own graph or gate authority, launch subagents as
independent graph owners, or access private authority/proof keys. A result is
evidence for the top-level session; it is not integration or human-gate approval.
