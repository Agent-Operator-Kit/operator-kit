# Operator V5 Control Graph

This directory is the local durable V5 execution graph. The runtime owns:

- `definition.json`: current typed graph definition;
- `events.jsonl`: append-only transaction journal;
- `projection.json`: deterministic current state and leases;
- `.lock`: transient cross-process transaction lock.

Use `bash scripts/operator-graph.sh`. Do not edit these files, create the lock,
or copy roadmap files into this directory. Product intent and priority planning
remain under the separate `roadmap/` directory.

Run `operator-graph validate` for full state validation, `operator-graph replay
check` to detect drift, and an explicitly request-ID'd `operator-graph replay
repair` to repair valid-journal drift.
