#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$KIT_ROOT/docs/concepts/operator-v5-lane-subagent-policy.md"
template="$KIT_ROOT/templates/prompts/lane-task.md"

fail() {
  printf 'v5 lane policy smoke failed: %s\n' "$1" >&2
  exit 1
}

require_file() {
  test -f "$1" || fail "missing file: $1"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "missing '$text' in ${file#"$KIT_ROOT"/}"
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "forbidden '$text' in ${file#"$KIT_ROOT"/}"
  fi
}

require_file "$policy"
require_file "$template"

require_text "$policy" '## Authority Table'
require_text "$policy" '| Control/operator task |'
require_text "$policy" '| Lane agent |'
require_text "$policy" '| Sub-agent |'
require_text "$policy" 'One lane agent is accountable for one assigned graph scope, branch, worktree,'
require_text "$policy" 'validation result, and handoff.'
require_text "$policy" 'One node ID, lease, and fence authorize exactly one mutable graph node.'
require_text "$policy" 'not authorize related or descendant nodes.'
require_text "$policy" 'descendant nodes separately as read-only context.'
require_text "$policy" 'Only the control/operator task changes queue priority, resolves cross-feature'
require_text "$policy" 'conflicts, or integrates branches.'
require_text "$policy" 'Operator and lane agents may use sub-agents for inspection, computation,'
require_text "$policy" 'testing, or explicitly delegated disjoint files inside the parent scope.'
require_text "$policy" 'Sub-agents never acquire graph nodes or leases, own branches or worktrees,'
require_text "$policy" 'commit, mutate queue or integration state, decide gates, merge, push, publish,'
require_text "$policy" 'or release.'
require_text "$policy" 'Same-worktree sub-agent edits are serialized by the parent lane'
require_text "$policy" 'The parent remains accountable and records outputs in its handoff.'
require_text "$policy" "A control/operator task records an authorized"
require_text "$policy" "human's gate decision; it does not decide a human gate."
require_text "$policy" 'Automated checks are'
require_text "$policy" 'validations or dependencies, not human gates.'
require_text "$policy" '## Allowed Examples'
require_text "$policy" '## Forbidden Examples'

for heading in \
  '## Task' \
  '## Graph Ownership' \
  '## Scope' \
  '## Contracts And Resources' \
  '## Parallel Safety' \
  '## Delegation' \
  '## Gates' \
  '## Acceptance Criteria' \
  '## Validation' \
  '## Handoff Requirements' \
  '## Memory Candidates'; do
  require_text "$template" "$heading"
done

for field in \
  '- Node ID:' \
  '- Graph scope:' \
  '- Related or descendant nodes (read-only):' \
  '- Lease ID:' \
  '- Lease expiry:' \
  '- Fence token:' \
  'Owned files or modules:' \
  'Read-only files or modules:' \
  '- Contracts:' \
  '- Shared resources:' \
  '- Delegation allowed:' \
  '- Required human gates:' \
  '- Decision authority: <authorized human>' \
  '- Decision recorder: <control/operator>' \
  '- Handoff path:' \
  '- Handoff owner:'; do
  require_text "$template" "$field"
done

require_text "$template" 'The node ID, lease, and fence authorize exactly one mutable graph node.'
require_text "$template" 'not authorize related or descendant nodes.'
require_text "$template" 'Only the control/operator task may change queue priority, resolve cross-feature'
require_text "$template" 'Sub-agents do not acquire graph nodes or leases, own branches or worktrees,'
require_text "$template" 'commit, mutate queue or integration state, decide gates, merge, push, publish,'
require_text "$template" 'The parent serializes all same-worktree edits'
require_text "$template" 'Automated checks are validations or dependencies, not'
require_text "$template" 'human gates.'
require_text "$template" 'If there are no candidates, write `- None.` explicitly.'

reject_text "$template" 'bounded descendants'
reject_text "$template" 'Gate authority:'
if grep -Eiq '^[[:space:]]*-[[:space:]]*Decision authority:.*control authority' "$template"; then
  fail "control authority cannot become human-gate decision authority"
fi

printf 'v5 lane policy smoke ok\n'
