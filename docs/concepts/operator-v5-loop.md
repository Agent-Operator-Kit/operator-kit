# Operator V5 Loop Runner And Heartbeat

Status: normative RM-0003 loop-runtime contract.

The V5 loop turns one trusted control snapshot into a bounded amount of host
work. It composes the RM-0007 graph and RM-0004 scheduler without becoming a
second graph authority: it does not read or repair graph files, hold proof
keys, select actor bindings, decide gates, or infer lease expiry from wall
time.

## CLI

```text
operator-loop tick [--dry-run] [--max-actions N] [--json]
operator-loop status [--json]
operator-loop pause [--reason TEXT] [--json]
operator-loop resume [--json]
```

`tick` defaults to one action and accepts a capacity from 0 through 10,000.
One process-wide singleton tick lease serializes tick execution for the same
`OPERATOR_DIR`; a concurrent tick fails with `LOOP_BUSY`. The singleton uses an
OS advisory lock, so process death releases exclusion without trusting a wall
clock. `loop/lease.json` is diagnostic durable evidence, not takeover
authority. It records the tick ID and current graph node lease ID/fence while a
runner is in flight and is removed on an orderly exit. A later tick may replace
an abandoned diagnostic record only after it owns the OS lock.

`pause` atomically prevents the next graph lease acquisition. It does not
terminate or revoke work that already holds a graph lease. The tick checks
pause state under a short state lock immediately before each claim, so pause
and claim have one ordering point while an in-flight runner continues and is
heartbeated. Repeated pause or resume calls do not rewrite state or increment
its generation.

`status` validates a fresh trusted snapshot and clock through scheduler
`status`, then reports pause state, any diagnostic active tick, runner and
mutation-launcher availability, and scheduler counts. It does not infer active
ownership merely from a host process name, tmux pane, or stale diagnostic
file.

## Trusted Host Interfaces

The host installs four absolute executable paths in the loop launch
environment:

| Variable | Input | Output |
| --- | --- | --- |
| `OPERATOR_LOOP_SNAPSHOT_COMMAND` | none | one raw `operator.control-snapshot/v1` or exact successful graph `snapshot`/`status` envelope |
| `OPERATOR_LOOP_CLOCK_COMMAND` | none | one current `operator.scheduler-clock/v1` record |
| `OPERATOR_LOOP_MUTATION_COMMAND` | one `operator.loop-mutation-request/v1` on stdin | the exact public RM-0007 mutation result envelope |
| `OPERATOR_LOOP_RUNNER_COMMAND` | one `operator.runner-request/v1` on stdin | one `operator.runner-result/v1` record |

Every invocation is a single request/response process. Inputs and outputs are
bounded canonical integer-only JSON; duplicate keys, floats, non-finite
numbers, invalid strings, unknown versions, unexpected fields, oversized
records, nonzero exits, and mismatched identities fail closed.

Snapshot, clock, mutation, scheduler, and runner processes execute with finite
timeouts and live stdout/stderr byte monitoring. Timeout and byte-limit
configuration is validated before any graph claim. Each child starts in its
own process group and the loop captures its PGID immediately after spawn. When
the loop can observe a timeout, output overflow, heartbeat failure, or other
forced stop, it sends TERM to that stable group, waits a bounded grace period,
then sends KILL if any group member remains—even if the direct child already
exited—and reaps the direct child separately. Test mode changes only scheduler
override selection, never process safety.

The snapshot and clock commands are trusted delivery boundaries, not file
selectors. The loop writes both outputs to private temporary files and passes
them to the shipped executable sibling `operator-scheduler.sh`; production
does not select a scheduler from the environment. A separately gated test mode
may provide an absolute executable override, but its output receives the same
full validation. Every scheduler call receives the delivered
`operator.control-snapshot/v1`, a current clock record, and an explicit bounded
capacity. The scheduler must echo the graph ID, revision, clock, and capacity.
The loop never constructs a clock from wall time, snapshot `updatedAt`, lease
`expiresAt`, or graph timestamps.

The loop accepts only the exact scheduler envelope for the requested command.
For `frontier`, every runnable or excluded entry must correspond one-for-one
to a snapshot candidate, preserve the immutable node fields, recompute its
claims from snapshot metadata and assigned lanes, and use the exact nested
reason schema. Duplicated, omitted, invented, rebound, or mismatched candidates
fail before mutation. `status` likewise requires exact count and reason shapes.

### Mutation launcher and proof broker

The mutation request has exactly these fields:

```json
{
  "schemaVersion": "operator.loop-mutation-request/v1",
  "action": "acquire",
  "graphId": "operator-v5",
  "nodeId": "task-1",
  "tickId": "8f2f...",
  "requestId": "loop-acquire-...",
  "expectedRevision": 12,
  "leaseId": "loop-...",
  "fence": null,
  "targetState": null,
  "ttlSeconds": 300
}
```

Actions are `acquire`, `renew`, `release`, and `transition`. Unused fields are
null. The loop supplies graph intent and CAS evidence but deliberately does
not supply an actor binding, holder scope, proof-key ID, private key, proof
signature, or broker socket. Trusted host policy authenticates the session,
fixes its permitted graph/binding/scope, and decides whether the requested
node is allowed.

A successful mutation reply is not accepted merely because it reports
`ok:true`. Its revision must equal `expectedRevision + 1`; its action and data
must have the exact action-specific schema; returned node, transition,
lease/fence, holder, clock, reclaimed flag, and release data must match the
request and pre-mutation snapshot. Malformed success replies fail closed. If
an acquire may have committed before its reply became unusable, the loop uses
a fresh trusted snapshot to recover only the exact requested lease identity,
then enters the normal failure/finalization/release path.

Public leases receive the same structural checks as RM-0007 plus exact
request/snapshot binding before they can reach a runner. Identifiers, hashes,
UTC timestamps, generation/fence counters, holder, and clock use canonical
bounded forms; times and monotonic expiry are ordered. The holder lane must be
an `assigned-to` lane for the node and its scope remains the canonical scope
selected by trusted host policy. Host, boot, and monotonic source must match
the delivered trusted clock epoch. Acquisition requires fence tombstone plus
one, an exact TTL in wall and monotonic time, and a `reclaimed` value matching
an actually expired, idempotent, reclaimable, safe-state prior snapshot lease.
Renewal preserves node, lease ID, fence, holder, acquisition time, and acquired
monotonic value; only renewal and expiry advance under the requested live TTL.

For each accepted mutation, the mutation launcher creates one fresh socket
pair, keeps the signing/keychain endpoint in the trusted host service, passes
only the other connected descriptor to `operator-graph --proof-fd`, and runs
the exact RM-0007 one-shot `authorize` then optional `event` protocol. It must
not reuse a socket or choose authority from request data, a readable binding,
or a challenge key ID. Private proof keys never enter the loop process,
repository, CLI, environment defaults, or `OPERATOR_DIR`. A graph error is
returned unchanged as one `{ok:false,error:{...}}` record. Production mutation
launch remains unavailable until a host adapter satisfies this boundary.

### Runner

After a successful graph lease acquisition, the loop sends:

```json
{
  "schemaVersion": "operator.runner-request/v1",
  "tickId": "8f2f...",
  "runId": "cf30...",
  "idempotencyKey": "sha256:...",
  "graphId": "operator-v5",
  "node": {
    "nodeId": "task-1",
    "kind": "task",
    "title": "Validate package",
    "claims": {"files": [], "contracts": [], "resources": [], "lanes": ["lane-ci"]}
  },
  "lease": {"leaseId": "loop-...", "fence": 4, "expiresAt": "2026-07-22T12:00:00Z"}
}
```

The idempotency key is stable for one graph/node pair across stale-owner
recovery. A host runner must fence any externally visible work with that key
and the current lease fence. Lease ID/fence alone grant no graph mutation
authority.

The runner returns exactly:

```json
{
  "schemaVersion": "operator.runner-result/v1",
  "runId": "cf30...",
  "nodeId": "task-1",
  "leaseId": "loop-...",
  "fence": 4,
  "status": "succeeded",
  "summary": "validation passed",
  "error": null
}
```

`status` is only `succeeded` or `failed`. A failed result requires an error
object; a successful result forbids one. `needs-runner` is never a successful
runtime result. If no runner is installed, a mutating tick returns
`NEEDS_RUNNER` before claiming anything. If an installed runner emits
`needs-runner`, malformed output, the wrong node/run/lease/fence, or times out,
the loop records failure and never completion.

The runner receives a deliberately minimal environment rather than the loop's
authority-bearing launch environment. In particular it does not inherit
`OPERATOR_DIR`, trusted interface command paths, or unrelated secrets; the
request on stdin is its data contract. Bounded stderr from a nonzero runner is
stored as base64url evidence so newlines, terminal controls, NULs, and invalid
UTF-8 cannot corrupt canonical event JSON.

## Bounded Tick

One non-dry tick performs this sequence:

1. Preflight the installed runner and trusted mutation launcher.
2. Acquire the singleton tick lease.
3. Obtain a trusted snapshot and current monotonic clock, then call scheduler
   `frontier` with the remaining capacity.
4. Under the pause lock, atomically request one RM-0007 graph lease with the
   snapshot revision as CAS. Lease conflicts and revision races cause a fresh
   evaluation; claim attempts are independently bounded.
5. Persist the returned lease ID/fence before starting the runner.
6. Run the host runner synchronously. For long work, obtain fresh trusted
   snapshot/clock evidence and renew the exact graph lease/fence before its
   TTL expires. Loss of renewal stops the runner.
7. On a runner result, transition the leased node to `active` and then
   `completed` or `failed`. A completion precondition failure is treated as
   failure and, when permitted, transitions `active` to `failed`. No runner or
   orchestration failure can mark success.
8. Release the exact lease/fence. Release errors are surfaced and the graph's
   expiry/reconciliation rules remain authoritative.
9. Append an `operator.loop-event/v1` observation to `loop/events.jsonl` with
   runner result, lease/fence, graph mutation revisions, outcome, and release
   error. RM-0007 transition and lease events remain the authoritative graph
   history; this loop journal is operational evidence only.
10. Refresh the frontier until the action capacity, empty frontier, pause, or
    bounded claim-attempt limit is reached, then release the singleton lease.

Once acquisition commits, every ordinary protocol, validation, subprocess,
timeout, and loop-I/O failure is routed through best-effort failed transition,
result evidence, and exact lease release. Exactly one loop event is appended
when the contained event journal remains writable. Persistent revision or
lease conflicts are returned as typed tick diagnostics instead of being
silently treated as an empty frontier.

Nodes remain `pending` or `ready` while their runner is executing. The graph
lease prevents a duplicate dispatch. This ordering is intentional: if the
loop crashes, RM-0007 may reclaim an expired owner only for work explicitly
marked both `idempotent` and `reclaimable`, and the stable runner idempotency
key makes the retry the same logical execution. Unsafe or active stale work
continues to require RM-0007 sweep and explicit reconciliation; the loop never
parses files or invents recovery.

`--dry-run` still acquires ephemeral process exclusion and validates the
trusted snapshot, clock, scheduler result, pause state, and bounded frontier.
It does not invoke the mutation launcher or runner and creates no durable loop
state, graph event, claim, result event, pause update, or lease record.

## Durable Loop State

Only loop-owned operational files are written:

```text
OPERATOR_DIR/loop/
├── state.json    # operator.loop-state/v1 pause state
├── lease.json    # operator.loop-lease/v1 active-tick diagnostic
└── events.jsonl  # append-only operator.loop-event/v1 observations
```

Writes are mode-0600, canonical JSON, temp-file-plus-fsync replacements for
state/lease, and append-plus-fsync for events. Corrupt loop state fails closed;
the loop does not repair it automatically. Direct writable access to
`OPERATOR_DIR/graph` remains a trusted control-plane operation and is not
required by this runtime.

All loop-owned opens, replacements, appends, and unlinks are anchored through
directory descriptors beneath the validated `OPERATOR_DIR/loop` directory and
use no-follow semantics. A symlinked or non-directory `OPERATOR_DIR`/`loop`, a
symlinked or non-regular loop file, or an object owned by another user is
rejected with stable `IO_ERROR`; no path is followed outside the loop state
root.

The contained loop directory must be owned by the effective user with mode
0700. Existing owned regular `state.json`, `lease.json`, and `events.jsonl`
files are tightened through their already validated anchored descriptors to
0600 before any read, write, or append. Unsafe ownership or object type remains
a hard failure.

## Stable Fail-Closed Diagnostics

Important codes include `LOOP_BUSY`, `NEEDS_RUNNER`, `BROKER_UNAVAILABLE`,
`TRUSTED_INTERFACE_UNAVAILABLE`, `INTERFACE_PROTOCOL`,
`MUTATION_INTERFACE_PROTOCOL`, `RUNNER_PROTOCOL`, `RUNNER_TIMEOUT`,
`LOOP_STATE_CORRUPT`, `IO_ERROR`, and `SCHEDULER_REJECTED`. CLI parse and usage
failures also emit one JSON error record with no argparse prose or traceback.
RM-0007 graph and RM-0004
scheduler error codes are surfaced when available, including
`REVISION_CONFLICT`, `LEASE_CONFLICT`, `FENCE_STALE`,
`RECONCILIATION_REQUIRED`, `TRUSTED_CLOCK_MISMATCH`, and `CORRUPT_JOURNAL`.

## Host Integration Boundary

RM-0005 owns production Codex and Claude implementations of the four trusted
commands, binding/scope policy, keychain-backed proof brokerage, runner
sandboxing, external-side-effect fencing, and process lifecycle. Shared
installer/update/version registration remains integration-owned. Host
metadata, tmux text, session titles, and task status are indexes and runner
inputs only; none can replace a graph event, lease/fence, scheduler result, or
recorded human gate.

Process groups cover every descendant termination the loop can initiate, but
they cannot solve parent-death cleanup: a runner can kill the loop parent and
remain alive. RM-0005 must supervise that descendant lifecycle. Every external
effect must also be fenced with the stable graph/node idempotency key and the
current RM-0007 fence; after a higher fence exists, a surviving stale runner
has no authority to commit an external effect. Host-adapter acceptance must
include a runner that kills its loop parent, survives, and is subsequently
reaped or contained by host supervision. RM-0003 does not claim to provide
that supervision.
