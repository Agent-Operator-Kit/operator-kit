# Lane Task Packet Template

## Task

- Goal: <desired outcome>
- Feature ID: <FS-ID>
- Roadmap ID: <RM-ID>
- Lane: <lane instance>
- Branch: <assigned branch>
- Worktree: <absolute worktree path>

## Graph Ownership

- Node ID: <single mutable graph node ID>
- Graph scope: <description bounded to the node above>
- Related or descendant nodes (read-only): <node IDs or none>
- Lease ID: <lease ID for the node above>
- Lease expiry: <timestamp>
- Fence token: <monotonically increasing fence value for the node above>
- Expected graph revision: <revision>

The node ID, lease, and fence authorize exactly one mutable graph node. They do
not authorize related or descendant nodes. The lane is accountable for this one
graph scope, branch, worktree, validation result, and handoff. Stop and return
control if the lease is missing or expired, the fence is stale, or ownership is
ambiguous or conflicting.

## Scope

Owned files or modules:

- <path or glob>

Read-only files or modules:

- <path or glob>

Do not modify files outside the owned list. Record any required out-of-scope
change as an integration follow-up.

## Contracts And Resources

- Role template: <role ID>
- Architecture patterns: <pattern IDs or existing project patterns>
- Approved packages/repos: use existing project-approved patterns first
- Dependency IDs: <node IDs or none>
- Contracts: <contract IDs or none>
- Shared resources: <resource IDs or none>
- Touched surfaces: <files, APIs, schemas, prompts, data, or design-system refs>

## Parallel Safety

- Safe to run in parallel with: <node or lane IDs, or none>
- Must serialize after: <node or lane IDs, or none>
- Conflict notes: <known overlap or none>

Only the control/operator task may change queue priority, resolve cross-feature
conflicts, or integrate branches.

## Delegation

- Delegation allowed: <none; inspection/computation/testing; or explicitly delegated disjoint file edits>
- Delegable files: <owned file subset or none>
- Delegated tasks: <sub-agent, bounded task, and expected output, or none>
- Same-worktree schedule: <serialized writer order or none>
- Handoff evidence required: <scope, outcome, validation, and disposition>

Sub-agents do not acquire graph nodes or leases, own branches or worktrees,
commit, mutate queue or integration state, decide gates, merge, push, publish,
or release. The parent serializes all same-worktree edits, reviews every
delegated output, remains accountable for the final diff and validation, and
records the output in its handoff.

## Gates

- Required human gates: <gate IDs and transition protected, or none>
- Decision authority: <authorized human>
- Decision recorder: <control/operator>
- Recorded decision/evidence: <event reference or pending>

Do not infer gate approval from silence, successful validation, host metadata,
or filesystem/tool access. Stop before a gated transition unless the required
decision is recorded. Automated checks are validations or dependencies, not
human gates.

## Acceptance Criteria

- <observable criterion>
- <observable criterion>

## Validation

```bash
<validation command>
```

- Expected result: <result>
- Skipped or unavailable checks: <reason or none>

## Handoff Requirements

- Handoff path: <absolute handoff path>
- Handoff owner: <parent lane agent>

Report:

- node ID, read-only related or descendant nodes, lease ID and expiry, fence
  token, branch, and worktree
- changed files
- acceptance criteria met or missed
- validation commands and exact results
- sub-agent tasks, bounded scopes/files, outputs, evidence, and disposition
- blockers
- integration follow-ups
- commit SHA when committing is authorized

## Memory Candidates

List only context worth considering for future retrieval:

- durable decision
- project fact
- task constraint
- failed approach
- validation finding
- follow-up needed from another lane

If there are no candidates, write `- None.` explicitly.
