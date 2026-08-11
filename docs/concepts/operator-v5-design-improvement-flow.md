# Operator V5 Three-Proposal Design And Forward Improvement Flow

Status: normative RM-0006 design-flow contract.

The design flow creates three comparable, independently executable proposals,
preserves an explicit human selection, and turns later dissatisfaction into
new forward work. It composes the RM-0007 graph, RM-0004 scheduler, RM-0003
loop, and existing feedback/planner ownership boundaries. It does not create a
second graph, feedback, planning, or authority model.

## CLI

```text
operator-design-flow start \
  --feature FS-0008 --feature-node FS-0008 --flow-id design \
  --brief /path/to/brief.md --lane design-lane [--title TEXT] [--json]

operator-design-flow status \
  --feature FS-0008 --flow-id design [--json]

operator-design-flow select \
  --feature FS-0008 --feature-node FS-0008 --flow-id design \
  --proposal proposal-a --lane implementation-lane [--json]

operator-design-flow reject \
  --feature FS-0008 --feature-node FS-0008 --flow-id design [--json]

operator-design-flow dissatisfied \
  --feature FS-0008 --feature-node FS-0008 --flow-id design \
  --lane design-lane --request-id review-20260722-01 --message TEXT \
  [--evidence /path/to/file]... [--json]
```

`--feature-node` defaults to the feature-session ID. `--request-id` is
mandatory for dissatisfaction because it is the durable idempotency identity
for both FB intake and forward graph work.

## Graph Shape And Lifecycle

`start` makes one atomic definition replacement through the trusted host
launcher. It appends exactly three sibling proposal nodes and one gate:

```text
feature
├── proposal-a ─┐
├── proposal-b ─┼── selected implementation ──> forward improvement 001 ──> ...
├── proposal-c ─┘                │
└── selection-gate ── gated-by ──┘
```

All three proposal nodes are `task` work assigned to the requested lane.
`select` first commits the explicit RM-0007 human approval and only then
appends the selected implementation definition. The implementation depends on
all three completed proposals and has a `gated-by` edge protecting `active`
and `completed`. If the process stops after approval, status reports a durable
approved gate with `implementation:null` and `materializationPending:true`;
this is a coherent retry state, not graph corruption. A later `select` with
the same proposal resumes materialization even if unrelated valid graph events
advanced the journal in between. The matching terminal gate event and current
approved state must remain replay-valid, but the gate event need not remain
the journal tail. The design-flow process never leases, activates, completes,
or runs graph work itself.

`reject` records `rejected` through the same human-gate API and does not create
implementation work. Gate decisions are terminal. A changed direction is new
forward work, not a rewritten selection.

Each `dissatisfied` request first asks the feedback-owning host interface for
idempotent FB inbox creation. It then appends one `feedback` work node with:

- `depends-on` the completed current outcome;
- `feedback-for` the original selected implementation;
- `assigned-to` the requested lane; and
- immutable metadata binding the FB ID, request ID, evidence path, sequence,
  and source node.

The prior implementation and earlier improvement nodes remain unchanged.
Another dissatisfaction request is rejected until the current forward node is
completed, producing an append-only improvement chain.

## Artifact And Evidence Boundary

All design artifacts are external to the repository:

```text
OPERATOR_DIR/features/<FS-id-slug>/work/design-options/
├── brief.md
├── proposal-a/
│   ├── brief.md
│   ├── prompt.md
│   └── <worker evidence>
├── proposal-b/
├── proposal-c/
└── improvements/
    └── improvement-<request-hash>/
        ├── dissatisfaction.md
        └── evidence/
```

Artifact files are evidence only. Their presence never decides the gate,
activates work, completes a node, or establishes authority. Existing artifacts
must match an idempotent retry; the command will not overwrite different
content. Symlinked workspaces, artifact directories, briefs, and evidence fail
closed.

## Trusted Interfaces

The installed entrypoint hardwires its trusted sibling providers: `operator-graph.sh`
for snapshots and graph mutations, and `operator-feedback.sh` for feedback intake.
Callers cannot select provider executables. `OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND`,
`OPERATOR_DESIGN_FLOW_MUTATION_COMMAND`, and
`OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND` are rejected when present; the obsolete
`OPERATOR_DESIGN_FLOW_GRAPH_MUTATION_HOST_COMMAND` override is rejected as well.
The graph sibling returns the exact RM-0007 snapshot envelope and accepts only a
bounded `operator.design-flow-graph-mutation-request/v1`; the feedback sibling
accepts only a bounded `operator.design-flow-feedback-request/v1` and returns one
`operator.design-flow-feedback-result/v1`.

Every trusted interface inherits the design command's already-open
`OPERATOR_DIR` descriptor. The child receives that descriptor as
`OPERATOR_DESIGN_FLOW_ROOT_FD`, its exact device/inode tuple in
`OPERATOR_DESIGN_FLOW_ROOT_DEV` and `OPERATOR_DESIGN_FLOW_ROOT_INO`, and the
original configured pathname in `OPERATOR_DESIGN_FLOW_ROOT_PATH`.
`OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE=exclusive-held` states that the design
entrypoint retains the one migration-wide root `LOCK_EX`. Nested providers and
brokers must validate and duplicate that capability; they must never call
`flock` or `LOCK_UN` on a duplicate because duplicates share the parent's open
file description and could convert or release its lock.
The textual `OPERATOR_DIR` remains available for compatibility, but trusted
providers must use the inherited descriptor for anchored traversal, compare
its `fstat` identity to the supplied tuple, and reverify the original pathname
immediately before an effect. They must retain and honor this contract through
any nested launcher. The design command also reverifies the original pathname
immediately before and after each interface and again before returning. A
same-owner rename/replacement therefore fails with `IO_ERROR` and cannot split
artifact, graph, or feedback effects across two roots.

The graph launcher request supplies only canonical intent, graph identity, CAS
revision, request ID, and either the append-only replacement definition or the
gate decision. It never supplies actor binding, holder scope, authority key,
proof key ID, signature, private key, or broker descriptor. Trusted host policy
selects an operator/system identity for definition replacement and a real human
identity for `gate decide`, then performs RM-0007's one-shot authorization and
event-proof protocol. A launcher must not infer human authority from the CLI
caller or request payload.

Fresh V5 installs wire these interfaces to the installed production graph and
feedback adapters. Definition replacement and gate decisions use the real
one-shot design broker. That broker accepts only the exact canonical
start/select/improve delta or explicit select/reject gate intent, reloads and
replays current graph state through the held Operator root, and refuses proof
signing when action preconditions, feature/brief bindings, proposal completion,
gate history, feedback content, or evidence hashes do not match. Its proof may
come from the OS keychain provider or the supported external
`operator.design-proof-signer/v1` provider documented in
`operator-v5-host-runners.md`; neither provider changes the graph policy.

Successful mutation replies are checked for exact command, request ID,
`expectedRevision + 1`, definition revision/counts, and gate transition data.
The command refreshes the trusted snapshot after mutation. Partial retries are
safe: an already-appended definition, approved gate, created feedback intake,
or forward node is discovered by immutable graph/request metadata and is not
duplicated.

The feedback interface owns FB allocation and planner-compatible inbox state.
The design-flow process passes only dissatisfaction content and feature-local
evidence references; it does not open or rewrite roadmap inbox files.

## Status Contract

`status --json` returns `operator.design-flow-status/v1` with graph and
definition revisions, exactly three proposal records, bounded evidence
inventories, gate state, selected proposal, implementation state, and all
forward improvement records. `durableGraphGate` becomes true only when the
trusted snapshot reports a terminal RM-0007 gate state. Status does not infer
approval from files, task text, prompts, or host metadata.

## Security Boundary

- Bootstrap and update restore the installed proposal prompt only through a
  held, no-follow `OPERATOR_DIR` descriptor. `prompts` must be an owned real
  directory and an existing `design-proposal.md` must be an owned single-link
  regular file. Dangling, final-leaf, and intermediate-directory symlinks are
  refused without writing their targets; only a genuinely absent leaf is
  installed at mode `0644` beneath a mode-`0700` prompts directory.
- Never read or write `OPERATOR_DIR/graph`, graph locks, bindings, authority
  anchors, proof sockets, or private keys directly.
- Never expose graph or feedback state directories to a proposal worker.
- Never grant one proposal write access to a sibling proposal directory.
- Never run implementation from `select`; RM-0003 owns leasing and execution.
- Never reopen completed nodes. Use FB intake and new forward graph work.
- Reject malformed, non-canonical, oversized, timed-out, identity-mismatched,
  or revision-mismatched trusted-interface replies.
