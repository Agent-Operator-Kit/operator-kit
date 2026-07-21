# Operator V5 Control Graph

This directory is the local V5 execution authority:

- `bindings/`: trusted actor/capability records provisioned by the control plane;
- `definition.json`: current normalized typed graph;
- `events.jsonl`: append-only committed transaction journal;
- `projection.json`: deterministic current state, leases, and fence tombstones;
- `.lock`: transient host-aware transaction lock.

Keep `bindings/` and its files non-symlinked and non-group/world-writable. A
process able to modify a binding has that binding's local authority. Bindings
are filesystem capabilities, not remote authentication.

Use `bash scripts/operator-graph.sh`; never edit graph files or create the lock
directly. Schedulers and runners consume `status` or `snapshot`, not files.
Roadmap state remains separate under `roadmap/`.

Run `validate` for state validation, `replay check` for deterministic drift
detection, and an explicitly request-ID'd, operator/system-bound `replay repair`
only when the journal is valid.
