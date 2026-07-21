# Operator V5 Control Graph

Status: normative V5 graph, event, projection, and ownership-lease contract.

This API is the sole owner of V5 node and edge shapes, graph-state
transitions, graph revisions, request idempotency, event journaling, ownership
leases, fencing, graph locking, and replay. The scheduler and heartbeat consume
this contract; they do not write its files directly.

## Durable State And Transaction Order

For the configured `OPERATOR_DIR`, graph state has exactly these durable files:

```text
OPERATOR_DIR/graph/
├── definition.json
├── projection.json
└── events.jsonl
```

`events.jsonl` is the append-only transaction record. `definition.json` and
`projection.json` are deterministic materializations. The writer uses the
portable atomic directory lock `graph/.lock`, appends one canonical JSON event
and calls `fsync`, then atomically replaces each changed materialization using
a same-directory temporary file, `fsync`, and `replace`. The lock is transient
and must never be treated as durable state.

All graph writes go through `scripts/operator-graph.sh`. A process must never
edit a graph file or hold `graph/.lock` itself. Graph commands never read or
write `OPERATOR_DIR/roadmap`.

The version identifiers are:

- `operator.control-graph/v1`
- `operator.control-event/v1`
- `operator.control-projection/v1`
- `operator.ownership-lease/v1`

An unknown identifier fails closed with `UNKNOWN_VERSION`. JSON Schemas live
under `schemas/operator-v5/`; cross-record constraints such as references,
endpoint kinds, cycles, replay ordering, and current fences are enforced by the
runtime.

## Definition

A definition has `schemaVersion`, a stable `graphId`, `nodes`, `edges`, and a
runtime-owned positive `definitionRevision`. Input definitions may omit
`definitionRevision`; init sets it to 1 and each successful replacement
increments it. Replacement cannot change `graphId`. Existing state is retained
when a node keeps the same ID and kind. A new or kind-changed node starts at its
declared initial state. Removing or changing the kind of a leased node is
rejected.

Node kinds and families are:

| Family | Node kinds | Initial state |
| --- | --- | --- |
| container | `goal`, `feature`, `lane` | `planned` |
| work | `task`, `validation`, `integration`, `feedback` | `pending` |
| gate | `human-gate` | `pending` |

Node IDs are unique. A node also has a title, integer priority from 0 through
1000, and JSON-object metadata. Missing titles default to the node ID, missing
priorities to 0, missing metadata to `{}`, and missing initial states to the
family default.

Edge IDs and `(kind, from, to)` tuples are unique. Missing edge IDs are derived
as `<kind>:<from>:<to>`. Both endpoints must exist and self-edges are invalid.
Allowed endpoint combinations are:

| Edge | From | To |
| --- | --- | --- |
| `contains` | goal, feature, lane | every kind except goal |
| `depends-on` | every kind except human-gate | every node kind |
| `assigned-to` | task, validation, integration, feedback | lane |
| `validated-by` | task, integration | validation |
| `gated-by` | goal, feature, task, integration | human-gate |
| `integrates-into` | integration | feature |
| `feedback-for` | feedback | every kind except feedback |

The combined directed subgraph formed by `contains` and `depends-on` edges must
be acyclic. Invalid references, kinds, combinations, duplicate records, and
cycles fail with `INVALID_GRAPH`.

## Published State Transitions

Transitions not listed here fail with `INVALID_TRANSITION`. Terminal states do
not reopen; dissatisfaction produces a new feedback/improvement node.

```text
containers
planned   -> active | blocked | cancelled
active    -> blocked | completed | cancelled
blocked   -> active | cancelled

work
pending   -> ready | blocked | cancelled
ready     -> active | blocked | cancelled
active    -> blocked | completed | failed | cancelled
blocked   -> ready | active | failed | cancelled
failed    -> ready | cancelled

human gates (only through `gate decide`)
pending   -> approved | rejected
```

An unleased transition is a control-plane operation and is allowed only to an
`operator`, `system`, or `human` actor. If a node has a lease, every transition
must supply its current lease ID and fence, and the actor must match the lease
holder. An expired lease cannot transition. Human gates cannot use the generic
transition command.

## Actors And Authority

Every event identifies an actor `type` and nonempty actor `id`. Actor types are
`operator`, `lane`, `host`, `human`, `subagent`, and `system`.

Only `human` may decide a human gate. Subagents cannot acquire, renew, or
release leases; replace definitions or change priority; decide gates; or
transition integration nodes. They may act only inside authority retained by
their parent and never become graph owners. Human gates are not leaseable.

## Events, Revisions, CAS, And Idempotency

Every successful mutation has a nonempty `requestId`. It appends exactly one
event with a strict, gap-free sequence. The sequence is also the resulting
projection `revision`. Events record schema version, sequence, event ID,
request ID, RFC 3339 time, actor, event type, type-specific data, and the exact
JSON result returned to the caller.

Mutation commands accept `--expected-revision`. A mismatch returns
`REVISION_CONFLICT` without appending. Request lookup occurs before the CAS
check: retrying an already committed `requestId` returns the original result
byte-for-byte in semantic JSON and appends nothing, even if the expected
revision is now old. Request IDs are unique for the lifetime of a journal and
must not be reused for unrelated intent.

`init` is idempotent. With no graph state it writes event 1 and both
materializations. With a complete, valid existing graph it returns
`alreadyInitialized: true` and changes nothing. Partial, corrupt, unknown, or
drifted state is never overwritten by init.

## Ownership Leases And Fencing

A lease contains its schema version, node ID, lease ID, holder
`{actorType, actorId, scope}`, acquire/renew/expiry timestamps, and positive
integer fence. TTL is 1 through 86400 seconds.

Only one unexpired lease can exist for a node. Acquire, renew, release, sweep,
and transition run under the graph transaction lock. Every acquisition uses a
fence greater than every prior lease fence for that node. An acquire after
expiry is a reclaim and increments the fence. Release and sweep remove the
active lease but retain the last fence. A stale lease ID or fence cannot renew,
release, or transition after reclaim.

`lease sweep` records one event containing all leases expired at the supplied
transaction time. A sweep with no expired leases still records the request,
making the operation retry-safe.

## Replay

Replay validates every journal line, requires a trailing newline, a strict
sequence beginning with `graph.initialized`, unique request IDs, known event
types and versions, valid event data, and internally consistent transitions.
It then recreates the semantic definition and projection. `replay check`
returns success only when both materializations match replay exactly and
otherwise returns `REPLAY_DRIFT`.

Repair is explicit. `replay repair` first reconstructs from the valid journal,
optionally checks the journal revision with CAS, appends a `replay.repaired`
event, and atomically replaces both materializations. It cannot repair a
corrupt or unknown-version journal.

## CLI

The shell entry point resolves `OPERATOR_DIR` from the environment or the
project's `operator.config.env`. The Python entry point also accepts the global
`--operator-dir PATH` option. Public commands are:

```text
operator-graph init [--definition FILE] [--graph-id ID] MUTATION
operator-graph validate [DEFINITION]
operator-graph status
operator-graph replace-definition DEFINITION MUTATION
operator-graph transition NODE STATE [--lease-id ID --fence N] MUTATION
operator-graph gate decide NODE approved|rejected MUTATION
operator-graph lease acquire NODE [--lease-id ID] [--holder-scope SCOPE]
    [--ttl-seconds N] MUTATION
operator-graph lease renew NODE --lease-id ID --fence N
    [--ttl-seconds N] MUTATION
operator-graph lease release NODE --lease-id ID --fence N MUTATION
operator-graph lease sweep MUTATION
operator-graph replay check
operator-graph replay repair MUTATION

MUTATION := --request-id ID [--expected-revision N]
            [--actor-type TYPE] [--actor-id ID] [--now RFC3339]
```

`init` has no expected revision because no projection exists. `--now` supports
deterministic automation; ordinary callers omit it. Success is one compact JSON
object on stdout with `ok: true`, `command`, and `data`; mutation results also
contain `requestId` and `revision`. Failure is one compact JSON object on stderr
with `ok: false` and `error: {code, message, details?}`.

Stable error codes are `USAGE`, `IO_ERROR`, `UNKNOWN_VERSION`, `INVALID_GRAPH`,
`REVISION_CONFLICT`, `REQUEST_CONFLICT`, `AUTHORITY_DENIED`, `LEASE_CONFLICT`,
`FENCE_STALE`, `INVALID_TRANSITION`, `REPLAY_DRIFT`, `CORRUPT_JOURNAL`,
`NOT_INITIALIZED`, `INVALID_STATE`, `LOCK_TIMEOUT`, `LEASE_REQUIRED`, and
`LEASE_EXPIRED`. Their process exit codes are defined in
`scripts/operator_graph.py`; callers should branch on the JSON code, not parse
messages.

## Integration Follow-Ups

- Register the script, schemas, template graph directory, and smoke test once
  integration owns the shared installer/updater/version lists.
- RM-0004 should consume `status` and the published edge/state vocabulary,
  perform all writes with request IDs and CAS, and never edit the projection.
- RM-0003 should pass host/lane lease ID and fence on owner transitions, use
  `lease sweep` for recovery, and treat replay drift or unknown versions as a
  closed control loop.
- RM-0001 authority policy should retain this runtime's subagent denials as the
  enforcement boundary even if adapters provide earlier advisory checks.
