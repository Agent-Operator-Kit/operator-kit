# Operator Kit V5 Lane And Sub-Agent Ownership Policy

Status: normative V5 authority contract.

This policy refines the operating model in
[`operator-v5.md`](operator-v5.md). If host metadata, runner behavior, or a task
packet conflicts with this policy, execution fails closed until the
control/operator task resolves the conflict. A host session or sub-agent does
not gain authority merely because it can access a repository or tool.

## Authority Table

| Actor | Owns and may decide | May delegate | Must not do |
| --- | --- | --- | --- |
| Human gate authority | The recorded decisions required by the graph, including subjective selection, stable-branch integration, push, publish, and release gates | Advice and evidence gathering, but not the decision itself | Treat silence, host metadata, or a successful validation as gate approval |
| Control/operator task | Graph assignment and queue priority; cross-feature conflict resolution; integration order and branch integration; release coordination; recording gate decisions from the authorized human | Inspection, computation, testing, or explicitly scoped disjoint file edits inside the control task's own scope | Transfer control authority merely by starting a lane or sub-agent; bypass a required human gate |
| Lane agent | One assigned graph scope containing exactly one mutable node, its valid node-specific lease and fence, one branch, one worktree, the scope's validation result, and its handoff | Inspection, computation, testing, or explicitly delegated disjoint files inside the assigned lane scope | Change queue priority; resolve cross-feature conflicts; integrate branches; widen its graph scope; mutate related or descendant nodes; use stale lease or fence authority |
| Sub-agent | Only the bounded work explicitly delegated by its parent; its output is evidence returned to that parent | Nothing; sub-agents cannot create another authority layer | Acquire graph nodes or leases; own a branch or worktree; commit, mutate queue or integration state, decide gates, merge, push, publish, or release |

One lane agent is accountable for one assigned graph scope, branch, worktree,
validation result, and handoff. A lane MUST confirm its node ID, lease, fence,
branch, worktree, owned files, read-only files, contracts, resources, gates, and
acceptance criteria before it mutates the assigned scope. It MUST stop and
return control when ownership is missing, expired, fenced out, ambiguous, or in
conflict with another active scope.

One node ID, lease, and fence authorize exactly one mutable graph node. They do
not authorize related or descendant nodes. A lane MUST list any related or
descendant nodes separately as read-only context. Mutating another node requires
a separate assignment with its own lease and fence from the control/operator
task.

Only the control/operator task changes queue priority, resolves cross-feature
conflicts, or integrates branches. A lane may report a conflict, propose an
ordering, prepare integration evidence, and commit its assigned branch; those
actions do not authorize it to make the control decision. A lane may push its
assigned branch only when its task packet explicitly authorizes the push and
the required gate has been recorded.

## Delegation Boundary

Operator and lane agents may use sub-agents for inspection, computation,
testing, or explicitly delegated disjoint files inside the parent scope. The
parent MUST define the delegated outcome and boundaries before work starts and
MUST reject output that exceeds them.

Sub-agents never acquire graph nodes or leases, own branches or worktrees,
commit, mutate queue or integration state, decide gates, merge, push, publish,
or release. A parent lease does not become a sub-agent lease, and a parent MUST
NOT represent a sub-agent as an independent graph owner. Sub-agent completion
is not graph completion: the parent evaluates the result, incorporates or
rejects it, and remains responsible for acceptance and validation.

Delegated file edits MUST be disjoint from every concurrent edit scope.
Same-worktree sub-agent edits are serialized by the parent lane: there is one
writer at a time, and the parent reviews the worktree state before the next
writer starts. A parent MUST NOT ask multiple sub-agents to edit the same
worktree concurrently, even when their intended files are disjoint. If parallel
edits require independent worktrees or branches, they require separate lane
scopes assigned by the control/operator task rather than sub-agent delegation.

The parent remains accountable and records outputs in its handoff. For each
sub-agent contribution the handoff MUST identify the delegated task, bounded
scope or files, outcome, evidence or validation used by the parent, and whether
the output was accepted, modified, or rejected. The parent, not the sub-agent,
owns the final diff, commit, validation statement, blockers, and memory
candidates.

## Allowed Examples

- A lane asks a sub-agent to inspect read-only API definitions and return a
  compatibility report. The lane verifies the report before changing its owned
  files.
- A lane delegates a calculation or fixture analysis that does not mutate graph
  state, then uses the result as evidence in its own validation.
- A lane asks one sub-agent to edit an explicitly listed test file inside the
  lane's owned files. The parent pauses its own writes, reviews the resulting
  diff, runs validation, and records the contribution in the handoff.
- The control task delegates a read-only comparison of two lane handoffs, then
  retains the conflict and integration decisions itself.
- Two disjoint graph nodes run in parallel only after the control task assigns
  each to a separate lane with its own branch, worktree, and lease.

## Forbidden Examples

- A sub-agent claims or renews a graph lease, transitions a node, or acts with
  the parent's fence token.
- A sub-agent creates or owns a branch or worktree, commits as the lane owner,
  merges a branch, pushes a commit, publishes an artifact, or starts a release.
- A lane reprioritizes the runnable frontier, resolves an overlap with another
  feature, or integrates its branch because its tests passed.
- A lane treats an expired lease, stale fence, host session, tmux pane, task
  title, or filesystem access as current graph authority.
- A parent allows itself and a sub-agent, or two sub-agents, to write the same
  worktree concurrently.
- A sub-agent approves a human gate or treats inspection, computation, or test
  success as approval.

## Validation And Handoff

The lane agent MUST run or explicitly account for every validation command in
its packet. It owns the truthfulness of the validation result even when a
sub-agent ran a command. Failed, skipped, unavailable, or out-of-scope checks
MUST be reported without being converted into success.

The handoff MUST include the assigned node ID, lease and fence observed, branch,
worktree, read-only related or descendant nodes, changed files, validation
commands and results, acceptance status, sub-agent contributions, blockers,
integration follow-ups, and memory candidates. The handoff transfers evidence
to the control task; it does not transfer integration authority or imply that a
human gate has been satisfied. A control/operator task records an authorized
human's gate decision; it does not decide a human gate. Automated checks are
validations or dependencies, not human gates.
