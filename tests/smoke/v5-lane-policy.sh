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

require_file "$policy"
require_file "$template"

require_text "$policy" '## Authority Table'
require_text "$policy" '| Control/operator task |'
require_text "$policy" '| Lane agent |'
require_text "$policy" '| Sub-agent |'
require_text "$policy" 'One lane agent is accountable for one assigned graph scope, branch, worktree,'
require_text "$policy" 'validation result, and handoff.'
require_text "$policy" 'Only the control/operator task changes queue priority, resolves cross-feature'
require_text "$policy" 'conflicts, or integrates branches.'
require_text "$policy" 'Operator and lane agents may use sub-agents for inspection, computation,'
require_text "$policy" 'testing, or explicitly delegated disjoint files inside the parent scope.'
require_text "$policy" 'Sub-agents never acquire graph nodes or leases, own branches or worktrees,'
require_text "$policy" 'commit, mutate queue or integration state, decide gates, merge, push, publish,'
require_text "$policy" 'or release.'
require_text "$policy" 'Same-worktree sub-agent edits are serialized by the parent lane'
require_text "$policy" 'The parent remains accountable and records outputs in its handoff.'
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
  '- Lease ID:' \
  '- Lease expiry:' \
  '- Fence token:' \
  'Owned files or modules:' \
  'Read-only files or modules:' \
  '- Contracts:' \
  '- Shared resources:' \
  '- Delegation allowed:' \
  '- Required gates:' \
  '- Handoff path:' \
  '- Handoff owner:'; do
  require_text "$template" "$field"
done

require_text "$template" 'Only the control/operator task may change queue priority, resolve cross-feature'
require_text "$template" 'Sub-agents do not acquire graph nodes or leases, own branches or worktrees,'
require_text "$template" 'commit, mutate queue or integration state, decide gates, merge, push, publish,'
require_text "$template" 'The parent serializes all same-worktree edits'
require_text "$template" 'If there are no candidates, write `- None.` explicitly.'

printf 'v5 lane policy smoke ok\n'
