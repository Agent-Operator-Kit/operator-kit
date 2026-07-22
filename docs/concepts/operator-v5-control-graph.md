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

Bindings are signed capability documents with caller proof keys, not trusted
filesystem labels or bearer credentials. The
control plane provisions `control-graph-public-key.json` with project ID,
graph ID, key ID, canonical host ID, and an RSA public key. Its private key
must never be present in a lane, worktree, `OPERATOR_DIR`, environment
variable, or CLI argument. The trust anchor must be mounted or otherwise kept
outside every bypass-permissions lane's write scope. A lane may rewrite a
mode-0600 binding file but cannot create the required RS256 signature.
Replacing the public-key anchor or runtime is control-plane compromise. The
initialized journal pins the authority key ID and canonical anchor hash, so an
anchor substitution without rewriting authenticated history fails closed. OS
sandboxing remains the boundary against rewriting the anchor, runtime, and
entire journal together.

Versions include `operator.control-graph/v1`, `operator.control-event/v1`,
`operator.control-projection/v1`, `operator.ownership-lease/v1`,
`operator.actor-binding/v1`, `operator.control-snapshot/v1`, and the mutation
authorization, unsigned-event, event-proof, proof-challenge, and proof-response
wire records described below. Unknown persisted or wire versions fail closed.
Committed JSON Schemas cover all eleven records. Runtime validation additionally
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

Before ready, active, or completed, all `depends-on` targets must be
success-terminal. Before completed, all `validated-by` targets must be
success-terminal. Gate checks
then apply. Transaction and replay enforce the same rules.

An unleased generic transition is restricted to operator/system. If a lease
exists, lease ID, fence, binding generation, and binding hash must match.
Human gates use only `gate decide`. Subagents cannot integrate.

## Operator Canonical JSON v1

All hashed, signed, journaled, or materialized JSON uses the normative
`Operator Canonical JSON v1` byte algorithm. Implementations must produce the
same bytes without relying on Python behavior:

1. The value domain is JSON objects with unique string keys, arrays, strings,
   booleans, null, and mathematical integers. Floating-point values—including
   integral-looking `1.0` or exponent forms parsed as floats—are invalid at any
   depth. `NaN` and infinities are invalid. Strings and keys contain Unicode
   scalar values but no surrogates, C0 controls (`U+0000..U+001F`), DEL, or C1
   controls (`U+007F..U+009F`). Application depth, item, and byte bounds still
   apply.
2. Recursively sort every object by increasing Unicode code-point sequence of
   its keys. Arrays preserve order. Unicode is not normalized.
3. Encode strings as JSON strings: escape quotation mark and reverse solidus as
   `\"` and `\\`; do not escape solidus; emit every other accepted Unicode
   scalar directly rather than as a `\u` escape.
4. Encode integers in minimal base-10 form: ASCII digits, a leading `-` only
   for negative values, no leading zeroes, and zero as `0`. Encode booleans and
   null as lowercase `true`, `false`, and `null`.
5. Use `,` and `:` separators with no whitespace. Encode the resulting text as
   UTF-8 and append exactly one byte `0A` (LF). That LF is part of the hashed or
   signed bytes.

Strict raw JSON parsing precedes structure validation, hashing, signing, and
persistence at every file or wire ingress. It rejects every float token,
including integral-looking decimal (`1.0`) and exponent (`1e0`) forms, as well
as negative zero (`-0`), before conversion can erase its lexical form. Ordinary
JSON Schema cannot enforce this distinction: standard `type: integer` is
semantic and some validators accept mathematically integral `1.0` or exponent
values. The committed schemas therefore validate structure and semantic value
classes, while their `$comment` requires this additional Operator Canonical
JSON v1 lexical layer. Schema validation alone is insufficient.

The public application-value depth limit is 32, counting the application root
as depth 1. Canonicalization remains bounded but reserves 8 additional levels
for runtime-owned event, event-proof, and proof-challenge envelopes, for a hard
canonical depth limit of 40. This allowance does not permit application inputs
deeper than 32; it ensures a definition valid exactly at depth 32 remains valid
when signed and committed inside the prescribed envelopes.

The integer-only rule is a hardening change: any earlier graph metadata or
history containing a finite float is no longer valid V1 state and requires a
stopped-writer, reviewed offline migration before this runtime can consume it.

Normative test vector semantic value:

```json
{"z":null,"a":{"β":"snowman ☃","a":[3,true,false,null],"escape":"quote\" backslash\\ solidus/"},"integer":-42,"unicode":"é"}
```

Exact canonical UTF-8 text (followed by one LF):

```text
{"a":{"a":[3,true,false,null],"escape":"quote\" backslash\\ solidus/","β":"snowman ☃"},"integer":-42,"unicode":"é","z":null}
```

Exact bytes and digest:

```text
hex = 7b2261223a7b2261223a5b332c747275652c66616c73652c6e756c6c5d2c22657363617065223a2271756f74655c22206261636b736c6173685c5c20736f6c696475732f222c22ceb2223a22736e6f776d616e20e29883227d2c22696e7465676572223a2d34322c22756e69636f6465223a22c3a9222c227a223a6e756c6c7d0a
sha256 = ae2327526275dee3f5a3920e7b56fba6249a19e46af484b3965327d412dfa12e
```

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
  "proofKey":{"keyId":"lane-control-graph-pop-4","algorithm":"RS256",
              "publicKey":{"n":"...","e":65537}},
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

Possession of this readable document is insufficient. Every mutation also
requires `--proof-fd N`, an inherited, connected, full-duplex stream socket to
a trusted host proof broker. One connection serves exactly one mutation and is
a one-shot state machine: at most one `authorize` challenge and, only after its
valid response, at most one `event` challenge. Every challenge and response is
one newline-delimited JSON record. The proof key ID is fixed by the first
challenge for the whole connection. Duplicate, reordered, unknown, or extra
records; phase, version, or key confusion; a key change between phases; and any
record after `event` fail closed.

After a valid `authorize` response, either side may observe EOF without an
`event` phase when the command produces no candidate append—for example an
exact retry, already-initialized result, CAS conflict, failed precondition, or
other post-authorization exit. This authorize-only EOF is a valid aborted or
no-append termination, and all session state is discarded. EOF before a
requested response, or EOF with a partial JSON record, is failure. After a
valid `event` response the broker must close its socket write side. The runtime
requires clean EOF within one second before accepting the event proof; any
same-read or delayed bytes, partial record, or writer left open fails
`AUTHORITY_DENIED` before journal append. The graph side then closes the whole
session.

The runtime sends `operator.proof-challenge/v1` records containing one of two
canonical payloads:

1. `authorize` carries `operator.mutation-proof-request/v1` and covers command,
   request ID, binding ID/generation/hash, complete intent, and CAS;
2. `event` carries `operator.mutation-event-proof/v1` and covers the complete
   materialized unsigned event, including event identity,
   trusted clock, actor snapshot, intent, CAS, data, and exact result.

The broker returns a strict `operator.proof-response/v1` record with the same
phase and key ID plus an RS256 signature. Authorization challenges are limited
to 64 KiB, event challenges to the 8 MiB event bound plus a 64 KiB envelope,
and responses to 4 KiB. These are different limits: a valid event proof may be
larger than 64 KiB. Both signatures are verified before append and persisted
for replay. Changing a CLI label, copying an operator/human binding, using a
lane key with an operator binding, or altering request/intent/CAS/event content
fails `AUTHORITY_DENIED`.

RS256 signs the `Operator Canonical JSON v1` bytes of the phase payload record
only—`operator.mutation-proof-request/v1` for `authorize` or
`operator.mutation-event-proof/v1` for `event`—not the enclosing
`operator.proof-challenge/v1` record. Authorization proves permission to
attempt that exact canonical mutation. Event proof approves the fully
materialized candidate event. Neither broker response is a durable-append
acknowledgement: failure can still occur after event signing and before append.
Only the successful graph command result, corroborated by replay/status/
snapshot, is commit evidence.

The host broker selects the signing key from trusted launcher/session policy
and independently checks that the challenge key is the authorized key for that
session. It must never select authority from `--actor-binding`, an untrusted
binding document, or the challenge's `proofKeyId` alone.

Private proof keys must never enter `OPERATOR_DIR`, a repository, a task
packet, environment defaults, CLI arguments, or the graph process. RM-0003 and
RM-0005 must use an OS-keychain or isolated broker: create a socket pair, keep
the signing/keychain end in the trusted host service, and pass only the graph
end as an inherited descriptor. There is deliberately no key-file option.
Production mutations remain disabled until that broker integration and the
permission-bypass removal described below are complete.
There are no shipped actor, capability, scope, time, proof, or fault-injection
shortcuts. Adversarial tests use a non-installed ephemeral broker against
isolated temporary state.

Each event snapshots binding generation, project/graph/key IDs, authority
anchor hash, validity window, subject, capabilities, scopes, proof verifier,
and canonical binding/capability hashes. It retains the authority signature
and both caller proof signatures. Replay verifies all signatures against the
pinned anchor and recorded proof key, then recomputes hashes without consulting
the current binding file.

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
- `complete`: only after ordinary dependency, validation, and gate completion
  preconditions pass, clear reconciliation and record adjudicated completion.

`binding-rotated` and `clock-recovery` resolve a still-present lease only when
the holder document has actually advanced generation/content or the persisted
host/boot/monotonic source has actually changed. A replacement binding must
have been issued no later than the resolution event; a future-dated document
is not rotation evidence. A higher-generation replacement that was already
issued but has since expired remains valid historical evidence of rotation.
False reason assertions fail `RECONCILIATION_REQUIRED`. Terminal work cannot
be leased.

## Trusted Time

Binding validity uses canonical-host wall time. Lease expiry uses a genuine
cross-process boot-relative clock: Linux reads `/proc/uptime`; macOS calls
`mach_continuous_time` and applies `mach_timebase_info` using Python's standard
library `ctypes`. Unsupported platforms or unavailable sources return
`CLOCK_UNAVAILABLE`; persisted expiry never falls back to `time.monotonic`, a
process-relative epoch, or wall-derived boot time. Foreign hosts and changed
boots or monotonic sources never expire a lease; they require explicit
`clock-recovery`. Wall-clock skew alone is not proof of a clock-source
discontinuity and cannot authorize `clock-recovery`.
Mutations on a host other than the trust anchor's `canonicalHostId` fail.

Event wall time is nondecreasing and bounded against same-host/boot monotonic
elapsed time. Rollback returns `CLOCK_ROLLBACK`; excessive forward movement
returns `CLOCK_SKEW`. Callers cannot inject clocks.

## Events, CAS, And Idempotency

Every mutation requires a bounded request ID and appends one event. Event
sequence is strict, gap-free, and equals projection revision. Event IDs and
request IDs are globally unique in the journal.

Events persist canonical `intent` and `expectedRevision`. Replay recomputes the
request fingerprint over command, request ID, binding ID/generation/hash,
intent, and CAS, then verifies the caller signatures over request and complete
event.
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

`status` and `snapshot` return the same locked deterministic
`operator.control-snapshot/v1` object: normalized
nodes/edges/metadata/states, leases, fence tombstones, execution-start markers,
reconciliations, binding generations, hashes, revisions, time, and event count.
They are operationally read-only but not guaranteed filesystem-no-write
operations: under the transaction lock they may quarantine/truncate an
incomplete journal tail or roll a fully committed event forward into stale
materializations. Sandboxed lanes therefore do not receive graph write access;
RM-0004 receives snapshots through a trusted host delivery boundary.

Replay validates versions, sizes, finite JSON, exact fields/results, unique
event/request IDs, recomputed authorization/request hashes, intent/CAS,
time/clock order, capabilities, assignment, transitions/preconditions,
reconciliation, expiry, fences, and immutable history. Corruption is
`CORRUPT_JOURNAL`; it is not repaired.

The runtime bounds IDs/scopes, JSON depth/items, node/edge counts, 64 KiB
metadata, 4 MiB graphs, 8 MiB event records, and a 256 MiB journal. Cycle and
JSON validation are iterative where recursion risk matters. Application values
are limited to depth 32; only the fixed runtime-owned canonical envelopes may
use the separate 8-level allowance described above.

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

MUTATION := --request-id ID --actor-binding ID --proof-fd FD [--expected-revision N]
```

Stable error codes include `USAGE`, `IO_ERROR`, `UNKNOWN_VERSION`,
`INVALID_GRAPH`, `REVISION_CONFLICT`, `REQUEST_CONFLICT`, `AUTHORITY_DENIED`,
`LEASE_CONFLICT`, `FENCE_STALE`, `INVALID_TRANSITION`, `REPLAY_DRIFT`,
`CORRUPT_JOURNAL`, `NOT_INITIALIZED`, `INVALID_STATE`, `LOCK_TIMEOUT`,
`LEASE_REQUIRED`, `LEASE_EXPIRED`, `PRECONDITION_FAILED`, `GATE_REQUIRED`,
`RECONCILIATION_REQUIRED`, `CLOCK_ROLLBACK`, `CLOCK_SKEW`, `CLOCK_UNAVAILABLE`,
and `JOURNAL_FULL`.

## Remaining Boundaries And Integration Follow-Ups

- Trust-anchor/private-key provisioning, signed binding issuance/rotation,
  proof-broker/keychain operation, and offline journal migration are
  control-plane/installer responsibilities.
- RS256 documents provide local authorization, not remote identity federation
  or protection after trust-anchor/runtime compromise.
- Host/boot/clock changes fail closed and require correction or explicit lease
  recovery; this API is not an independent time service.
- Register the runtime, eleven schemas, template, and smoke in shared installer,
  updater, and version surfaces on the integration branch.
- RM-0004 consumes only trusted-host-delivered snapshot/status output and
  surfaces precondition, gate, reconciliation, clock, and journal-full
  failures; it does not gain graph-directory write access.
- RM-0003/RM-0005 select signed bindings, connect the matching keychain-backed
  proof broker over a fresh inherited socket per mutation, enforce the strict
  two-phase record protocol, select its key from trusted host policy, persist
  lease ID/fence, and never retry reconciled work until an explicit resolution
  is observed. Production mutation launch remains disabled until this exists.
- The downstream launcher integration must remove permission-bypass execution
  and OS-sandbox each Codex/Claude lane so it can write only its worktree and
  its own handoff directory; graph state, bindings, anchors, and runtime stay
  outside that writable boundary.
