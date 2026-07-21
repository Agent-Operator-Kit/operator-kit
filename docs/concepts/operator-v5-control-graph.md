# Operator V5 Control Graph

Status: normative V5 graph, transaction, actor-binding, event, projection, and
ownership-lease contract.

This API is the sole owner of V5 node and edge shapes, graph-state
preconditions and transitions, graph revisions, request idempotency, event
journaling, actor capabilities, ownership leases, fencing, graph locking, and
replay. Schedulers and runners consume the locked snapshot API and never parse
or write graph files.

## Durable State And Trust Boundary

For the configured `OPERATOR_DIR`, graph state is:

```text
OPERATOR_DIR/graph/
├── bindings/
│   └── <binding-id>.json
├── definition.json
├── projection.json
└── events.jsonl
```

`events.jsonl` is the append-only transaction record. `definition.json` and
`projection.json` are deterministic materializations. `bindings/` is trusted
local configuration provisioned by the control plane or authorized human; it
is not event history.

The local filesystem is the security boundary. `bindings/` and each binding
must be real, non-symlinked, non-group/world-writable paths. Any process that
can replace a trusted binding or modify the runtime has equivalent local
control-plane authority. Bindings are not remote authentication, signatures,
or protection from a compromised local account. Deployments with mutually
untrusted OS users must provision ownership/ACL isolation outside this API.

Graph commands write no roadmap files. Product intent remains under
`OPERATOR_DIR/roadmap`; it is not runtime authority.

Version identifiers are:

- `operator.control-graph/v1`
- `operator.control-event/v1`
- `operator.control-projection/v1`
- `operator.ownership-lease/v1`
- `operator.actor-binding/v1`

Unknown versions fail closed with `UNKNOWN_VERSION`. Committed JSON Schemas
cover graph, event, projection, and lease records. Runtime checks add
cross-record constraints: references, endpoint kinds, cycles, transition
preconditions, event semantics, timestamps, assignments, and fences.

## Typed Definition

A definition has `schemaVersion`, stable `graphId`, normalized `nodes` and
`edges`, and runtime-owned positive `definitionRevision`. Input definitions may
omit `definitionRevision`; init sets it to 1 and every replacement increments
it.

Node families are:

| Family | Kinds | Default state | Success-terminal |
| --- | --- | --- | --- |
| container | `goal`, `feature`, `lane` | `planned` | `completed` |
| work | `task`, `validation`, `integration`, `feedback` | `pending` | `completed` |
| gate | `human-gate` | `pending` | `approved` |

Node IDs are unique. A node has a title, priority from 0 through 1000, and
object metadata. Missing title, priority, metadata, and initial state normalize
to the node ID, 0, `{}`, and the family default.

Work may opt into automatic expired-lease reclaim only with both flags:

```json
{"execution":{"idempotent":true,"reclaimable":true}}
```

Omission or either false value means reclaim requires explicit sweep and
reconciliation.

Allowed edge endpoints are:

| Edge | From | To |
| --- | --- | --- |
| `contains` | goal, feature, lane | every kind except goal |
| `depends-on` | every kind except human-gate | every node kind |
| `assigned-to` | task, validation, integration, feedback | lane |
| `validated-by` | task, integration | validation |
| `gated-by` | goal, feature, task, integration | human-gate |
| `integrates-into` | integration | feature |
| `feedback-for` | feedback | every kind except feedback |

Edge IDs and `(kind, from, to)` tuples are unique. Both endpoints must exist,
self-edges are invalid, and the combined directed `contains`/`depends-on`
subgraph must be acyclic.

### Gate Metadata

Every `gated-by` edge normalizes metadata to:

```json
{"protectedTransitions":["active","completed"]}
```

That safe default applies to non-integration sources. The integration default
is `ready`, `active`, and `completed`, so integration cannot begin without an
explicit approved gate. A nonempty, unique `protectedTransitions` array may
narrow or expand protection to valid states of the source family.

For every protected transition, every applicable gate must exist, be a
`human-gate`, and be `approved`. Pending, rejected, cancelled, missing, or
invalid gates fail closed. Integration transitions to ready, active, or
completed additionally require at least one applicable `gated-by` edge;
absence returns `GATE_REQUIRED`.

### Append-Only Identity

Definition replacement cannot change `graphId`, remove an existing node ID, or
change an existing node's kind. Node IDs therefore cannot be reused and fence
tombstones never reset.

Once a node has moved from its original state, or is terminal, its kind, title,
initial state, metadata, and outgoing dependency, validation, gate, assignment,
and integration edges are immutable. This prevents definition replacement from
deleting execution preconditions after work begins while still allowing new
forward nodes to contain, depend on, or link feedback to completed history.
Priority remains control-plane state and may change through an operator/system
definition replacement.
Completed history is never reopened or rewritten; new cancellation, feedback,
or forward-improvement nodes carry later work.

## Published Transitions And Preconditions

Unlisted transitions return `INVALID_TRANSITION`:

```text
containers
planned -> active | blocked | cancelled
active  -> blocked | completed | cancelled
blocked -> active | cancelled

work
pending -> ready | blocked | cancelled
ready   -> active | blocked | cancelled
active  -> blocked | completed | failed | cancelled
blocked -> ready | active | failed | cancelled
failed  -> ready | cancelled

human gates (only `gate decide`)
pending -> approved | rejected
```

Before a node becomes `ready` or `active`, every `depends-on` target must be
success-terminal for its family. Before a node becomes `completed`, every
`validated-by` target must be success-terminal. Gate checks then apply to the
target state. These checks run inside the transaction lock and again during
replay, so a scheduler bug or forged journal cannot bypass them.

An unleased generic transition is a control-plane operation available only to
an operator or system binding with `transition`. If a current lease
exists, the command must supply its lease ID and fence and use the same actor
binding that owns the lease. An expired lease cannot transition. Human gates
never use generic transition.

## Actor Binding And Capabilities

Mutations require `--actor-binding ID`. The runtime resolves only
`OPERATOR_DIR/graph/bindings/ID.json`; callers cannot supply arbitrary paths.

```json
{
  "schemaVersion": "operator.actor-binding/v1",
  "bindingId": "lane-control-graph",
  "subject": {
    "type": "lane",
    "id": "control-graph-worker",
    "laneNodeId": "lane-control-graph"
  },
  "capabilities": ["lease", "transition"],
  "leaseScopes": [
    {"scope": "lane:control-graph", "laneNodeId": "lane-control-graph"}
  ]
}
```

Subject types are `operator`, `lane`, `host`, `human`, `subagent`, and
`system`. Lane subjects require `laneNodeId`; host subjects require
`hostRunnerId`. Only lane and host bindings may contain lease scopes. Each
scope binds a structured scope string to exactly one lane node. A lane binding
cannot name another lane's node; a host must list every allowed lane scope
explicitly.

Capabilities are `graph-init`, `graph-replace`, `gate-decision`, `lease`,
`transition`, `sweep`, and `replay-repair`. `test-injection` is reserved for
isolated runtime tests.

Type restrictions remain even if an overpowered binding lists a capability:

- only operator/system may initialize or replace a graph, including priority;
- only human may decide a gate;
- only lane/host may acquire or hold a lease;
- only operator/system/host may sweep;
- only operator/system may repair replay drift;
- subagents cannot lease, decide gates, replace graph/priority, or integrate.

Changing `--actor-type` or `--actor-id` labels does not change a binding's
identity. Raw actor flags exist solely behind
`--test-only-unsafe-actor-flags` plus `OPERATOR_GRAPH_TESTING=1`; they are
hidden from normal help and require explicit test capabilities/scopes.

Each event snapshots binding ID, canonical binding hash, the complete typed
subject, capabilities, and lease scopes. Replay validates that the recorded
capability, actor type, scope, and lane assignment could perform the event
without consulting a mutable current binding.

## Assignment And Ownership Leases

Only work nodes can be leased. Acquire requires `--holder-scope`, and that
scope must appear in the binding. The node must have `assigned-to` pointing to
the scope's lane node. A lane cannot lease work assigned to another lane; host
identity alone never authorizes a scope.

A lease records node ID, lease ID, holder type/ID/binding/scope/lane node,
acquire/renew/expiry timestamps, and positive fence. TTL is 1 through 86400
seconds. Only one unexpired lease exists per node.

Every acquisition increments the retained per-node fence. Release and sweep
remove the active lease but retain the tombstone. Because definitions never
remove IDs, a remove/re-add sequence cannot restart fencing.

An expired lease is automatically reclaimable only when the node metadata is
both idempotent and reclaimable and its state is pending, ready, or blocked.
Active work is never automatically reclaimed. Other expired nonterminal work
returns `RECONCILIATION_REQUIRED` until `lease sweep` removes the lease and
moves the node to `blocked`, recording `reconciliation: true`. A later acquire
then receives the next fence. Terminal work retains its terminal state when an
expired lease is swept.

## Trusted Time

Authorization, expiration, reclaim, renewal, release, and transition use the
runtime's UTC wall clock. Public callers cannot inject time. Test time requires
all three: `OPERATOR_GRAPH_TESTING=1`, hidden `--test-only-now`, and a binding
with `test-injection`.

Event time is nondecreasing. A transaction whose trusted time precedes the
last event returns `CLOCK_ROLLBACK`; replay classifies backward journal time as
corruption. An ordinary actor therefore cannot claim that another lease has
expired by supplying a future timestamp.

## Events, Revisions, CAS, And Idempotency

Every mutation has a bounded `requestId` and appends exactly one committed
event. Event sequence is strict, gap-free, and equal to projection revision.
Definition revision is separate and changes only on replacement.

Events record a `requestFingerprint`: SHA-256 of canonical command intent,
binding ID/hash/subject, node and target or definition hash, lease/fence,
relevant command options, CAS revision, and test time when used. An exact retry
returns the original journaled result without appending. Reusing a request ID
with different command, binding, target, definition, lease/fence, TTL, scope,
or CAS returns `REQUEST_CONFLICT` before other state checks.

`--expected-revision` provides CAS for every mutation except init. A mismatch
returns `REVISION_CONFLICT` without an event.

## Journal Commit, Locking, And Recovery

The writer uses the atomic directory `graph/.lock`. Its owner record contains
host, boot, PID, process-start identity, token, heartbeat, and short expiry.
The owner refreshes its heartbeat during a transaction. Foreign-host PIDs are
never interpreted as local. A foreign live lease fails closed; an expired lock
may be recovered. On the same host/boot, a missing process or mismatched
process-start token detects death/PID reuse.

The commit order is:

1. append one canonical event ending in a newline commit marker;
2. `fsync` the journal;
3. replay the complete journal;
4. atomically temp+`fsync`+replace definition;
5. atomically temp+`fsync`+replace projection;
6. `fsync` parent directories.

An incomplete final record without the newline marker is uncommitted. Under
the lock it is truncated to the last committed newline. Invalid JSON or
semantics in any newline-committed record, including the middle, is
`CORRUPT_JOURNAL` and is never skipped.

If a fully committed event is ahead of a missing or lower-revision
materialization, the next locked command automatically rolls both
materializations forward before request lookup. An exact retry therefore
returns the committed original result after crashes following the event or
between definition/projection replacement. Same-revision semantic drift is
not silently repaired; `replay check` returns `REPLAY_DRIFT` and repair remains
explicit.

## Snapshot And Replay APIs

`status` and `snapshot` both acquire the graph lock and return the same
deterministic data object. It contains projection schema version, graph ID,
projection and definition revisions, definition hash, last event time, event
count, normalized sorted nodes with metadata and current state, normalized
sorted edges with metadata, active leases, and fence tombstones. RM-0004 and
RM-0003 consume this API rather than files.

Replay validates versions, sizes, JSON numbers, exact fields, strict sequence,
unique request IDs, request fingerprint shape, nondecreasing time, actor and
capability, event-specific data, exact command/result/data consistency,
assignment, state preconditions, lease order, expiry, fences, and history
immutability. `replay repair` appends an attributed repair event and atomically
replaces both materializations. It cannot repair a corrupt journal.

## Input Bounds

The runtime rejects non-finite numbers, control characters, overlong IDs and
scopes, unsafe binding paths, excessive node/edge counts, metadata over 64 KiB,
JSON nesting over 32, graph files over 4 MiB, event records over 8 MiB, and
journals over 256 MiB. Cycle validation is iterative, avoiding recursion
failure on large graphs. Invalid journal timestamps and values are reported as
`CORRUPT_JOURNAL`, never CLI usage errors or tracebacks.

## CLI

```text
operator-graph init [--definition FILE] [--graph-id ID] MUTATION
operator-graph validate [DEFINITION]
operator-graph status
operator-graph snapshot
operator-graph replace-definition DEFINITION MUTATION
operator-graph transition NODE STATE [--lease-id ID --fence N] MUTATION
operator-graph gate decide NODE approved|rejected MUTATION
operator-graph lease acquire NODE --holder-scope SCOPE
    [--lease-id ID] [--ttl-seconds N] MUTATION
operator-graph lease renew NODE --lease-id ID --fence N
    [--ttl-seconds N] MUTATION
operator-graph lease release NODE --lease-id ID --fence N MUTATION
operator-graph lease sweep MUTATION
operator-graph replay check
operator-graph replay repair MUTATION

MUTATION := --request-id ID --actor-binding ID [--expected-revision N]
```

The shell entry point resolves `OPERATOR_DIR` from the environment or project
config. Direct Python callers may put global `--operator-dir PATH` before the
command.

Success is compact JSON on stdout. Failure is compact JSON on stderr with
`ok:false` and `error:{code,message,details?}`. Callers branch on `error.code`,
not messages. Stable codes include `USAGE`, `IO_ERROR`, `UNKNOWN_VERSION`,
`INVALID_GRAPH`, `REVISION_CONFLICT`, `REQUEST_CONFLICT`, `AUTHORITY_DENIED`,
`LEASE_CONFLICT`, `FENCE_STALE`, `INVALID_TRANSITION`, `REPLAY_DRIFT`,
`CORRUPT_JOURNAL`, `NOT_INITIALIZED`, `INVALID_STATE`, `LOCK_TIMEOUT`,
`LEASE_REQUIRED`, `LEASE_EXPIRED`, `PRECONDITION_FAILED`, `GATE_REQUIRED`,
`RECONCILIATION_REQUIRED`, and `CLOCK_ROLLBACK`.

## Remaining Boundaries

- Binding provisioning/rotation is a control-plane and installer concern; this
  API validates and consumes bindings but does not mint authority.
- Local bindings are filesystem capabilities, not cryptographic remote tokens.
- The graph is intentionally bounded for deterministic single-writer local
  operation; larger distributed graphs require a different storage contract.
- Wall-clock rollback fails closed and requires host clock correction; the API
  does not operate an independent trusted-time service.

## Integration Follow-Ups

- Register the runtime, four schemas, graph template, and smoke in shared
  installer/updater/version surfaces, including creation of trusted
  `graph/bindings` with restrictive permissions.
- RM-0004 should consume only `snapshot`/`status`, surface
  `PRECONDITION_FAILED` and `GATE_REQUIRED` reasons, and use request IDs/CAS.
- RM-0003 should provision/select host or lane bindings, persist lease ID and
  fence, sweep expired work for reconciliation, and fail its tick closed on
  lock, clock, replay, or version errors.
- RM-0001/RM-0002 adapters should map durable lanes, feature instances, and host
  runners into binding subjects/scopes without granting host-derived authority.
