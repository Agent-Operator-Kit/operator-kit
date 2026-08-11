# Operator V5 Scheduler And Runnable Frontier

Status: normative RM-0004 scheduler contract.

The V5 scheduler derives a deterministic, read-only runnable frontier from one
validated `operator.control-snapshot/v1` value. It never reads graph
definition, projection, journal, binding, lease, lock, authority, roadmap, or
host-session files; invokes graph mutations; expires leases; or changes node
state or priority.

## Trusted Snapshot Boundary

Production control or host code obtains `operator-graph status` or
`operator-graph snapshot` and delivers its validated result to the scheduler.
The scheduler accepts either the raw snapshot object or the exact successful
public CLI envelope:

```json
{"ok":true,"command":"snapshot","data":{"schemaVersion":"operator.control-snapshot/v1"}}
```

The example abbreviates the snapshot only for readability. The actual `data`
object must contain every committed snapshot field and no unknown field.

Stdin is the default snapshot delivery channel. `--snapshot FILE` exists for
isolated tests and trusted host staging; pointing it at graph internals
violates this boundary. The scheduler does not invoke `operator-graph` itself
because even its operationally read-only commands may take the graph lock,
recover an incomplete journal tail, or roll materializations forward.

Ingress uses Operator Canonical JSON v1 lexical rules: unique object keys,
UTF-8, integers only, no negative zero or non-finite values, canonical strings,
and bounded size, depth, and item count. It validates the complete public
snapshot, including nodes, edges, execution metadata, leases and clocks,
execution-start markers, reconciliations, binding generations, fences, hashes,
references, endpoint kinds, assignment, and the combined
`contains`/`depends-on` acyclic invariant. Unsupported or malformed nested
values fail closed before any frontier is returned.
Lease-holder `bindingId` values and all `bindingGenerations` keys use the same
RM-0007 identifier grammar and are limited to 128 characters.

## Trusted Current Clock

Snapshot `updatedAt` is the wall time of the last graph event. It is not a
current-time observation and never determines lease liveness. Likewise,
`expiresAt` is informational wall time and is not safe for expiry decisions.
RM-0007 lease expiry is authoritative only within the matching monotonic boot
session.

When a snapshot contains any lease, the trusted host boundary must deliver a
separate `operator.scheduler-clock/v1` record with `--clock FILE`:

```json
{
  "schemaVersion": "operator.scheduler-clock/v1",
  "hostId": "host-1",
  "bootId": "boot-1",
  "monotonicSource": "linux-proc-uptime",
  "monotonicNs": 421000000000
}
```

The record has exactly those five fields. `hostId` and `bootId` are bounded
canonical strings; `monotonicSource` is `linux-proc-uptime` or
`macos-mach-continuous`; and `monotonicNs` is a non-negative integer. The host
must obtain the observation from the same trusted boot-session clock used by
RM-0007 and deliver it through the protected host/control boundary. The file
option is transport, not a trust grant: an untrusted lane-created record is
not trusted evidence.

For every lease, all three identity fields must exactly match the lease's
public `clock` record and current `monotonicNs` must be at least
`acquiredMonotonicNs`. A missing clock, host/boot/source mismatch, or monotonic
rollback fails the entire evaluation closed. With matching evidence, the
lease is stale exactly when:

```text
current monotonicNs >= lease.clock.expiresMonotonicNs
```

No clock is required when the snapshot contains no leases because no liveness
classification occurs. Reusing the same snapshot and current-clock record
produces the same result.

## Scheduler Metadata

The graph contract intentionally permits canonical node metadata. RM-0004 owns
one optional, strict extension beneath `node.metadata.scheduler`:

```json
{
  "scheduler": {
    "claims": {
      "files": ["scripts/example.sh"],
      "contracts": ["scheduler"],
      "resources": ["simulator:ios-1"],
      "lanes": ["lane:exclusive-runtime"]
    }
  }
}
```

The `scheduler` extension and `claims` field are optional. `claims` may contain
only the four shown arrays; every array contains unique, non-empty canonical
strings.
Values are exact identifiers: the scheduler does not normalize paths or infer
overlap between parent and child paths. A work node also implicitly claims
every lane node named by its public `assigned-to` edges. Public `blocked` state
is the pause representation: a blocked work node is paused, and a blocked
assigned lane pauses its work.

This metadata records conflict inputs; it is not a lease, lock, gate
decision, or mutation authority. RM-0003 owns pause/resume orchestration and is
responsible for updating the trusted snapshot through graph-authorized control
operations rather than writing state behind the graph.

## Eligibility

Only `task`, `validation`, `integration`, and `feedback` nodes are work
candidates. A candidate is eligible before selection when all conditions hold:

- state is `pending` or `ready`;
- it has at least one `assigned-to` lane;
- every `depends-on` target is success-terminal (`completed` for container or
  work nodes, `approved` for gates);
- every gate applicable to the candidate's upcoming transition is approved,
  and an integration has a gate;
- neither the work node nor any assigned lane has public state `blocked`;
- it has no reconciliation record;
- it has no lease live at the explicitly delivered trusted monotonic time; and
- a stale lease is reclaimable only when public execution metadata has both
  `idempotent` and `reclaimable` set to `true` and state is `pending`, `ready`,
  or `blocked`.

Lease liveness is never inferred from wall time or the scheduler process's
local clock. A safely reclaimable stale lease releases its claims for frontier
selection. A live lease or any stale lease that is not safely reclaimable
continues to reserve all file, contract, resource, explicit-lane, and
assigned-lane claims, even though the stale-unsafe node itself is excluded.
This prevents conflicting work from starting while prior execution may still
require reconciliation. The scheduler does not delete a lease or advance its
fence. The authorized graph runtime remains responsible for acquisition,
sweep, and reconciliation.

### Upcoming Gate Transitions

Gate applicability follows each public `gated-by.metadata.protectedTransitions`
array rather than the mere presence of an edge:

- a `pending` candidate checks gates protecting upcoming `ready` or `active`;
- a `ready` candidate checks gates protecting upcoming `active`;
- a gate protecting only `completed` does not block either candidate;
- a gate protecting only `ready` blocks `pending` but not `ready`; and
- a gate protecting `active` blocks both `pending` and `ready` until approved.

Pending/rejected/cancelled diagnostics include only applicable gates. The
RM-0007 integration invariant remains unchanged: every integration gate edge
must cover `ready`, `active`, and `completed`, and integration work without a
gate fails closed.

## Selection, Conflicts, And Capacity

Eligible candidates are ordered by:

1. descending numeric `priority`;
2. ascending node ID by Unicode code-point order.

Before new selection, the scheduler reserves claims for three independent
authorities:

- current leases, except safely reclaimable stale leases;
- every node with a `reconciliations` record; and
- every work node whose current state is `active`, even without a lease.

Each authority reserves file, contract, resource, explicit-lane, and
assigned-lane claims regardless of priority. Reconciliation retains claims
after an unsafe lease is swept until explicit graph resolution removes the
record. Active state retains claims after lease release until an authorized
state transition changes it. Permanent `executionStarted` markers and fence
history alone do not reserve claims.

The scheduler then walks the ordered candidates greedily. A candidate that
shares any exact claim with a reserved or earlier-selected scope is excluded.
A selected candidate reserves all its claims for the rest of that evaluation.
Independent claims remain parallel-runnable, including within the same
dependency diamond after predecessors complete.

`--capacity N` bounds newly selected nodes after eligibility and conflict
checks. `N` may be zero. The default is unbounded by RM-0004; RM-0003 may pass a
bounded tick capacity. Capacity never changes graph priority or state.

## Stable Diagnostics

Candidate exclusions use these stable reason codes:

| Code | Meaning |
| --- | --- |
| `STATE_UNSCHEDULABLE` | The work state is not `pending` or `ready`. |
| `ASSIGNMENT_MISSING` | The work has no public `assigned-to` lane. |
| `DEPENDENCY_INCOMPLETE` | A predecessor is valid but not success-terminal. |
| `DEPENDENCY_FAILED` | A predecessor is failed, rejected, or cancelled. |
| `DEPENDENCY_MISSING` | A referenced predecessor is absent. |
| `GATE_MISSING` | Integration work has no human gate. |
| `GATE_PENDING` | An applicable upcoming-transition gate is not decided. |
| `GATE_REJECTED` | An applicable upcoming-transition gate is rejected or cancelled. |
| `LEASE_LIVE` | The candidate has a live lease at snapshot time. |
| `LEASE_STALE_UNSAFE` | Its monotonic-stale lease is not safely reclaimable; its claims remain reserved. |
| `RECONCILIATION_REQUIRED` | Explicit lease adjudication is pending. |
| `PAUSED_NODE` | The work node is paused. |
| `PAUSED_LANE` | An assigned lane is paused. |
| `CONFLICT_FILE` | An exact file claim overlaps a reserved scope. |
| `CONFLICT_CONTRACT` | An exact contract claim overlaps a reserved scope. |
| `CONFLICT_RESOURCE` | An exact resource claim overlaps a reserved scope. |
| `CONFLICT_LANE` | An explicit or assigned lane overlaps a reserved scope. |
| `CAPACITY_EXHAUSTED` | The bounded selection count is already reached. |

Malformed input cannot safely produce per-node exclusions. It fails the whole
evaluation with stable diagnostics including `INVALID_NODE`, `INVALID_EDGE`,
`MISSING_DEPENDENCY`, `DEPENDENCY_CYCLE`, `INVALID_SNAPSHOT`, and
`UNKNOWN_SNAPSHOT_VERSION`. Lease-bearing snapshots additionally fail with
`TRUSTED_CLOCK_REQUIRED`, `TRUSTED_CLOCK_INVALID`,
`TRUSTED_CLOCK_MISMATCH`, or `TRUSTED_CLOCK_ROLLBACK` when current monotonic
evidence is absent or unsafe. This is deliberate fail-closed behavior: a
missing endpoint, cycle, or invalid node never permits unrelated work to start
from an untrusted partial interpretation.

Every graph CLI envelope command, nested enum, identifier, claim entry,
protected transition, endpoint, clock field, and reconciliation value is
type-checked before membership, deduplication, lookup, regex, or sorting.
Malformed object/list values therefore produce exactly one parseable
`{ok:false,error:...}` record on stderr with a documented nonzero code and no
traceback. A final narrow public-boundary guard converts residual validation
type/index/key failures to `INVALID_SNAPSHOT`; it does not replace the explicit
field validators.

Reason arrays are deterministic. Eligibility reasons precede conflict and
capacity reasons, dependency and gate IDs are sorted, conflict kinds use the
table order above, and excluded nodes retain candidate ordering.

## CLI And JSON

```text
operator-scheduler frontier [--snapshot FILE] [--clock FILE] [--graph ID] [--capacity N] [--json] [--explain]
operator-scheduler status   [--snapshot FILE] [--clock FILE] [--graph ID] [--capacity N] [--json]
```

Without `--snapshot`, both commands read one snapshot or public CLI envelope
from stdin. `--clock` supplies the separately trusted current monotonic record
and is mandatory for lease-bearing snapshots. Snapshot and clock cannot both
use stdin. `--graph` fails if the delivered snapshot has another graph ID.
`frontier` prints the ordered runnable IDs; `--explain` adds exclusions.
`--json` returns a stable `operator.scheduler-frontier/v1` result, with
exclusions included only when `--explain` is present.

`status` evaluates the same frontier and reports node/work/runnable/excluded
counts, live and stale lease counts, the clock evidence used, and counts for
every exclusion reason in `operator.scheduler-status/v1`. Frontier JSON also
echoes the clock evidence. Both commands are deterministic functions of the
delivered snapshot, trusted current-clock record, and explicit flags.

The scheduler's success envelope is `{ok,command,data}`. Failures are emitted
as `{ok:false,error:{code,message,details?}}` on stderr with a nonzero exit.
No command mutates the snapshot source, graph, roadmap, or lease state.
