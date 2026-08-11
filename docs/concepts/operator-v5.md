# Operator Kit V5 Architecture Baseline

Status: final V5 distribution contract.

Integrated distribution base: `701146c6bbbb4c526d1b4ff0671d662da6e47984`.

## Authority And Durable State

V5 uses this authority order:

1. committed architecture, schemas, and compatibility contracts;
2. the scheduled graph definition and append-only graph events under
   `OPERATOR_DIR/graph/`;
3. replayable graph projections and generated Operator views;
4. host metadata such as Codex tasks, Claude sessions, tmux windows, titles,
   pins, and monitors.

Host metadata is an index, never the source of truth. The local roadmap records
product intent and priority under `OPERATOR_DIR/roadmap/`; it does not become
the runtime execution graph and graph commands do not mutate roadmap items.

## Operating Model

The Operator heartbeat is a bounded, retryable loop over a typed control graph.
The graph contains goals, features, lanes, tasks, validations, human gates,
integration work, and forward feedback. The scheduler derives a deterministic
runnable frontier from graph state. Host runners execute only graph scopes for
which they hold valid ownership.

A feature creates temporary feature-scoped lane instances from project role
templates. A lane agent owns one assigned graph scope, branch, worktree,
validation result, and handoff. The control task owns queue-priority changes,
cross-feature conflict decisions, integration, and release coordination.

Operator and lane agents may use sub-agents within their assigned scope.
Sub-agents do not own graph nodes or leases, branches, worktrees, queue state,
integration, merge, push, publish, or release authority. The parent agent
remains accountable for their edits, evidence, validation, and handoff.

Codex and Claude are host runners over the same graph contract. A Codex goal or
Claude session may keep safe work moving, but host autonomy does not widen the
graph scope or bypass leases, conflicts, transition rules, or human gates.

## Human Gates

Human decisions protect explicit transitions rather than freezing an entire
project. V5 requires a recorded human decision before:

- selecting a subjective product or design proposal;
- integrating a feature into the stable branch;
- pushing, tagging, versioning, publishing, or releasing;
- changing credentials, provider consoles, production data, or destructive
  infrastructure;
- executing regulated, financial, safety-critical, or otherwise irreversible
  behavior that cannot be inferred safely.

Read-only inspection, specification, isolated implementation, and disposable
validation may continue when their graph dependencies, leases, and conflict
checks allow it.

## Feedback And History

Completed graph history is append-only. Normal dissatisfaction or a rejected
result creates a feedback record and a forward improvement node linked to the
prior outcome. It does not rewind, reopen, or rewrite completed execution.

## Reliability Contract

Every mutation is actor-attributed, request-idempotent, revision-checked, and
recorded as an event. Projections are derived and replayable. Ownership leases
use expiry plus monotonically increasing fencing so stale holders cannot
transition work after recovery. Invalid schemas, corrupt journals, ambiguous
ownership, missing gates, and unknown host runners fail closed.

V4 feature sessions, tasks, handoffs, roadmap items, and memory remain readable.
Migration into V5 graph state is explicit and lossless; V4 files are not
silently reinterpreted as the V5 source of truth.

## Implementation Ownership

- RM-0001 owns lane and sub-agent authority policy.
- RM-0002 owns the project role-map contract.
- RM-0007 owns graph schemas, events, transitions, leases, fencing, replay, and
  the public graph API.
- RM-0004 owns deterministic scheduling and runnable-frontier reason codes.
- RM-0003 owns bounded tick, status, pause, resume, and runner orchestration.
- RM-0005 owns Codex and Claude host-runner adapters.
- RM-0006 owns three-proposal design selection and forward improvement flow.

The final distribution registers every runtime, all eleven schemas, target-
derived role maps, explicit lossless V4 migration, version-aware status,
plugin/adapter compatibility metadata, and the combined installed-project
matrix. Installation creates private runtime directories only; it does not
initialize production graph history, authority/binding state, or keys.
