# Operator Kit V5.2 Architecture

Operator V5.2 is a local, human-supervised execution planner. It keeps the
useful part of the V5 design—a typed dependency graph and deterministic
runnable frontier—without turning local development into a cryptographic
control plane.

## Authority

The human and the Operator cockpit remain authoritative. Feature-session files,
task packets, worktrees, handoffs, validation evidence, and reviewed integration
are the operating record. The graph advises what can run next; it does not grant
execution authority and never dispatches work by itself.

Each feature owns one editable graph:

```text
OPERATOR_DIR/features/<FS-id-slug>/
├── status.json
├── graph.json
├── graph-events.jsonl
├── tasks/
├── handoffs/
└── work/
```

`graph.json` contains task, validation, integration, and feedback nodes. Nodes
have dependencies, a lane, priority, optional approval, and exact file,
contract, resource, and surface claims.

## Runnable Frontier

`operator-graph.sh frontier` considers active feature sessions together. A node
is runnable when:

- its state is `pending`;
- every dependency is `completed`;
- a lane is assigned;
- any requested human approval is approved; and
- its lane and claims do not conflict with active or already-selected work.

Candidates are ordered by descending priority and stable feature/node ID. The
default capacity is four and can be bounded explicitly. Cross-feature claims
prevent unsafe parallelism while disjoint work remains parallel-runnable.

## Optional Model Selection

V5.2 can evaluate one task against a reviewed project-local model catalog and
policy. Each candidate is one exact provider model plus one exact reasoning
setting. Operator filters hard constraints and quality evidence first, then
compares expected total tokens, retry/escalation risk, latency, and cost.

This capability is off by default and advisory only. Installation creates no
live catalog or policy and never applies a model setting to a lane or chat. Run
`operator-model-select.sh setup-guide` to see the user inputs required before
opting in.

## Deliberately Absent

V5.2 does not require or install:

- signing authorities or actor bindings;
- Keychain or Secret Service entries;
- proof brokers;
- ownership leases or fencing tokens;
- trusted-host bindings or `launchd` relays;
- autonomous heartbeat loops; or
- cryptographic graph replay.

These mechanisms are preserved in Git tag `v5.0-signed-control-plane` for a
future autonomous-execution edition.

## Human Gates

Graph approvals are visible planning signals, not security credentials. Human
intent is still required before integration, push, tag, release, credential or
provider changes, destructive operations, production changes, and other
irreversible work. A successful worker handoff never implies approval.

## Commands

```bash
bash scripts/operator-graph.sh init <feature>
bash scripts/operator-graph.sh add <feature> <node-id> "<title>" --lane <lane>
bash scripts/operator-graph.sh depend <feature> <node-id> <dependency-id>
bash scripts/operator-graph.sh approve <feature> <node-id> approved
bash scripts/operator-graph.sh set-state <feature> <node-id> completed
bash scripts/operator-graph.sh frontier [<feature>] [--capacity N]
bash scripts/operator-graph.sh status [<feature>]
bash scripts/operator-graph.sh validate [<feature>]
```

The graph command writes only the selected feature's `graph.json`, a small
advisory event log, and a local lock file. Files are ordinary local JSON and
can be inspected, backed up, or repaired by the user.
