# Operator V5 Control Graph

Status: normative V5 graph, transaction, signed authority, event, projection,
and ownership-lease contract.

This API is the sole owner of V5 node/edge shapes, transitions and
preconditions, revisions, idempotency, journaling, capabilities, ownership
leases, fencing, locking, and replay. Schedulers and runners consume `status`
or `snapshot`; they never parse or write graph files.

## Durable State And Trust Boundary

```text
OPERATOR_DIR/
├── authority/
│   └── control-graph-public-key.json
└── graph/
    ├── bindings/
    │   └── <binding-id>.json
    ├── definition.json
    ├── projection.json
    └── events.jsonl
```

`events.jsonl` is the append-only transaction record. `definition.json` and
`projection.json` are deterministic materializations. Graph commands never
write roadmap files.

Bindings are signed capability documents, not trusted filesystem labels. The
control plane provisions `control-graph-public-key.json` with project ID,
graph ID, key ID, canonical host ID, and an RSA public key. Its private key
must never be present in a lane, worktree, `OPERATOR_DIR`, environment
variable, or CLI argument. The trust anchor must be mounted or otherwise kept
outside every bypass-permissions lane's write scope. A lane may rewrite a
mode-0600 binding file but cannot create the required RS256 signature.
Replacing the public-key anchor or runtime is control-plane compromise.

Versions are `operator.control-graph/v1`, `operator.control-event/v1`,
`operator.control-projection/v1`, `operator.ownership-lease/v1`, and
`operator.actor-binding/v1`. Unknown persisted state versions fail closed.
Committed JSON Schemas cover all five records. Runtime validation additionally
enforces cross-record references, endpoints, cycles, transitions, assignment,
time, signatures, generations, and fences.

## Typed Definition

Definitions contain `schemaVersion`, stable `graphId`, nodes, edges, and a
runtime-owned positive `definitionRevision`. Input may omit the revision; init
sets 1 and replacement increments it.

| Family | Kinds | Required initial state | Success-terminal |
| --- | --- | --- | --- |
| container | goal, feature, lane | `planned` | `completed` |
| work | task, validation, integration, feedback | `pending` | `completed` |
| gate | human-gate | `pending` | `approved` |

An explicitly supplied non-default initial state is invalid. V1 has no
migration shortcut: activation, completion, and gate decisions must be
attributed events. Priority is an integer from 0 through 1000. Work opts into
safe expired-lease reclaim only with both flags:

```json
{"execution":{"idempotent":true,"reclaimable":true}}
```

Allowed edges are:

| Edge | From | To |
| --- | --- | --- |
| contains | goal, feature, lane | every kind except goal |
| depends-on | every kind except human-gate | every kind |
| assigned-to | work | lane |
| validated-by | task, integration | validation |
| gated-by | goal, feature, task, integration | human-gate |
| integrates-into | integration | feature |
| feedback-for | feedback | every kind except feedback |

References and IDs must be unique; self-edges are invalid. The combined
`contains`/`depends-on` graph must be acyclic.

### Gates

`gated-by` metadata normalizes to `protectedTransitions`. The safe default is
`["active","completed"]`; integration defaults to and must always cover
`ready`, `active`, and `completed`. Listed values must be actual transition
targets for the source family. JSON Schema validates the field shape and
values; runtime validation enforces source-node-specific coverage.

Every applicable gate must be approved. Missing, pending, rejected, cancelled,
or invalid gates fail closed. An integration transition to ready, active, or
completed without an applicable gate returns `GATE_REQUIRED`.

### Append-Only Identity

Replacement cannot change graph ID, remove or kind-change an existing node, or
reuse its ID. Fence tombstones therefore never reset. A work node becomes
execution-started on its first lease even while still pending; projection
records the first revision/time in `executionStarted`. From then on—or after
any node activates or becomes terminal—kind, title, initial state, metadata,
and outgoing assignment/dependency/validation/gate/integration edges are
immutable. Completed history is never reopened; forward work uses new nodes.

## Transitions And Preconditions

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

human gates (gate decide only)
pending -> approved | rejected
```

Before ready/active, all `depends-on` targets must be success-terminal. Before
completed, all `validated-by` targets must be success-terminal. Gate checks
then apply. Transaction and replay enforce the same rules.

An unleased generic transition is restricted to operator/system. If a lease
exists, lease ID, fence, binding generation, and binding hash must match.
Human gates use only `gate decide`. Subagents cannot integrate.

## Signed Actor Bindings

Mutations require `--actor-binding ID`, resolved only below `graph/bindings`.
A binding includes:

```json
{
  "schemaVersion":"operator.actor-binding/v1",
  "bindingId":"lane-control-graph",
  "generation":4,
  "projectId":"my-project",
  "graphId":"operator-v5",
  "issuedAt":"2026-07-21T08:00:00Z",
  "expiresAt":"2026-07-22T08:00:00Z",
  "subject":{"type":"lane","id":"worker","laneNodeId":"lane-control-graph"},
  "capabilities":["lease","transition"],
  "leaseScopes":[{"scope":"lane:control-graph","laneNodeId":"lane-control-graph"}],
  "signature":{"keyId":"control-2026-07","algorithm":"RS256","value":"..."}
}
```

Unsigned, altered, expired, wrong-project, wrong-graph, wrong-key, or
wrong-host authority fails `AUTHORITY_DENIED`. Generations only increase; old
or same-generation-different-content documents fail closed. Capabilities are
`graph-init`, `graph-replace`, `gate-decision`, `lease`, `transition`, `sweep`,
`lease-resolve`, and `replay-repair`.

Type rules still apply to an overpowered document:

- operator/system: init, replacement/priority, replay repair;
- human only: gate decision;
- lane/host only: acquire/hold lease;
- operator/system/host: sweep;
- operator/system/human: resolve reconciliation;
- subagents: never lease, decide gates, change graph/priority, or integrate.

There are no shipped actor, capability, scope, time, or fault-injection flags,
hidden or otherwise. Environment variables cannot mint authority. Adversarial
tests use a non-installed harness against isolated temporary state.

Each event snapshots binding generation, project/graph/key IDs, validity
window, subject, capabilities, scopes, and canonical binding/capability hashes.
It also retains the binding signature. Replay verifies that signature against
the external trust anchor and recomputes both hashes without consulting the
current binding file.

## Assignment, Leases, And Reconciliation

Only nonterminal work may be leased. The requested holder scope must be signed
into a lane/host binding and its lane node must match `assigned-to`. A lease
records holder binding ID/generation/hash, scope/lane, timestamps, canonical
host/boot monotonic clock, and fence. TTL is 1 through 86400 seconds.

Every acquisition increments the permanent per-node fence tombstone. Same-ID
binding rotation cannot inherit renew, release, or transition rights.

Safe idempotent/reclaimable pending, ready, or blocked work may be reclaimed
after monotonic expiry. Active or otherwise unsafe nonterminal work requires
reconciliation. `lease sweep` removes its lease, blocks active work, and
persists a `reconciliations` record; sweep alone never authorizes another run.
Operator/system/human must journal `lease resolve` with the retained lease
ID/fence:

- `retry`: clear reconciliation; active becomes blocked; then a new lease may
  acquire the next fence;
- `cancel`: clear reconciliation and mark cancelled;
- `complete`: clear reconciliation and record explicit adjudicated completion.

`binding-rotated` and `clock-recovery` resolve a still-present lease. Terminal
work cannot be leased.

## Trusted Time

Binding validity uses canonical-host wall time. Lease expiry uses the
canonical host/boot monotonic sample. Foreign hosts, changed boots, and skewed
wall clocks never expire a lease; they require explicit `clock-recovery`.
Mutations on a host other than the trust anchor's `canonicalHostId` fail.

Event wall time is nondecreasing and bounded against same-host/boot monotonic
elapsed time. Rollback returns `CLOCK_ROLLBACK`; excessive forward movement
returns `CLOCK_SKEW`. Callers cannot inject clocks.

## Events, CAS, And Idempotency

Every mutation requires a bounded request ID and appends one event. Event
sequence is strict, gap-free, and equals projection revision. Event IDs and
request IDs are globally unique in the journal.

Events persist canonical `intent` and `expectedRevision`. Replay recomputes the
request fingerprint over command, binding ID/hash/subject, intent, and CAS.
Exact retries return the original result without appending; changed intent
returns `REQUEST_CONFLICT`. Optional `--expected-revision` applies to every
mutation except init and returns `REVISION_CONFLICT` on mismatch.

## Locking, Commit, Recovery, And Journal Bounds

The atomic `graph/.lock` owner records host, boot, PID, process-start identity,
unique token/epoch, heartbeat, and diagnostic expiry. Expiry never authorizes
takeover of a live/paused owner. Foreign locks are never reclaimed from wall
time. Same-host/boot takeover requires proven death or PID reuse. Ownerless or
malformed locks are quarantined by atomic rename only after a conservative
grace period; creator failure removes the directory. Ownership is rechecked
immediately before append and every materialization replacement.

Under that lock the runtime:

1. recovers an incomplete tail and preflights committed size;
2. validates/replays the candidate event before modifying the journal;
3. appends one newline-committed canonical event and fsyncs;
4. atomically temp+fsync+replaces definition and projection, checking the lock
   token before each replacement.

An incomplete final line is truncated; committed middle/tail corruption is
never skipped. A committed event ahead of materialization rolls forward on the
next locked load, so an exact retry succeeds. Same-revision drift returns
`REPLAY_DRIFT`; only explicit `replay repair` rematerializes it.

No successful append may exceed 256 MiB. At the exact boundary the event is
accepted; the next mutation returns `JOURNAL_FULL`. V1 has no online checkpoint
or rotation API. Operators must stop writers and use separately reviewed,
signed migration/checkpoint tooling—never truncate or replace this journal in
place.

## Snapshot, Replay, And Bounds

`status` and `snapshot` return the same locked deterministic object: normalized
nodes/edges/metadata/states, leases, fence tombstones, execution-start markers,
reconciliations, binding generations, hashes, revisions, time, and event count.

Replay validates versions, sizes, finite JSON, exact fields/results, unique
event/request IDs, recomputed authorization/request hashes, intent/CAS,
time/clock order, capabilities, assignment, transitions/preconditions,
reconciliation, expiry, fences, and immutable history. Corruption is
`CORRUPT_JOURNAL`; it is not repaired.

The runtime bounds IDs/scopes, JSON depth/items, node/edge counts, 64 KiB
metadata, 4 MiB graphs, 8 MiB event records, and a 256 MiB journal. Cycle and
JSON validation are iterative where recursion risk matters.

## CLI

```text
operator-graph init [--definition FILE] [--graph-id ID] MUTATION
operator-graph validate [DEFINITION]
operator-graph status | snapshot
operator-graph replace-definition DEFINITION MUTATION
operator-graph transition NODE STATE [--lease-id ID --fence N] MUTATION
operator-graph gate decide NODE approved|rejected MUTATION
operator-graph lease acquire NODE --holder-scope SCOPE [--lease-id ID] [--ttl-seconds N] MUTATION
operator-graph lease renew NODE --lease-id ID --fence N [--ttl-seconds N] MUTATION
operator-graph lease release NODE --lease-id ID --fence N MUTATION
operator-graph lease sweep MUTATION
operator-graph lease resolve NODE retry|cancel|complete --lease-id ID --fence N
    --reason expired-unsafe|binding-rotated|clock-recovery MUTATION
operator-graph replay check
operator-graph replay repair MUTATION

MUTATION := --request-id ID --actor-binding ID [--expected-revision N]
```

Stable error codes include `USAGE`, `IO_ERROR`, `UNKNOWN_VERSION`,
`INVALID_GRAPH`, `REVISION_CONFLICT`, `REQUEST_CONFLICT`, `AUTHORITY_DENIED`,
`LEASE_CONFLICT`, `FENCE_STALE`, `INVALID_TRANSITION`, `REPLAY_DRIFT`,
`CORRUPT_JOURNAL`, `NOT_INITIALIZED`, `INVALID_STATE`, `LOCK_TIMEOUT`,
`LEASE_REQUIRED`, `LEASE_EXPIRED`, `PRECONDITION_FAILED`, `GATE_REQUIRED`,
`RECONCILIATION_REQUIRED`, `CLOCK_ROLLBACK`, `CLOCK_SKEW`, and `JOURNAL_FULL`.

## Remaining Boundaries And Integration Follow-Ups

- Trust-anchor/private-key provisioning, signed binding issuance/rotation, and
  offline journal migration are control-plane/installer responsibilities.
- RS256 documents provide local authorization, not remote identity federation
  or protection after trust-anchor/runtime compromise.
- Host/boot/clock changes fail closed and require correction or explicit lease
  recovery; this API is not an independent time service.
- Register the runtime, five schemas, template, and smoke in shared installer,
  updater, and version surfaces on the integration branch.
- RM-0004 consumes only snapshot/status and surfaces precondition, gate,
  reconciliation, clock, and journal-full failures.
- RM-0003 selects signed lane/host bindings, persists lease ID/fence, and never
  retries reconciled work until an explicit resolution is observed.
