#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-task.sh <slug> "<title>"

Creates $OPERATOR_DIR/tasks/<slug>/ with task and handoff folders.
USAGE
}

slug="${1:-}"
title="${2:-}"

if [ -z "$slug" ] || [ -z "$title" ]; then
  usage >&2
  exit 1
fi

case "$slug" in
  *[!a-zA-Z0-9._-]*)
    printf 'Invalid slug: %s\nUse only letters, numbers, dot, underscore, and dash.\n' "$slug" >&2
    exit 1
    ;;
esac

task_dir="$OPERATOR_DIR/tasks/$slug"
mkdir -p "$task_dir/tasks" "$task_dir/handoffs" "$OPERATOR_DIR/captures"

brief="$task_dir/00-operator-brief.md"
if [ ! -f "$brief" ]; then
  {
    printf '# %s\n\n' "$title"
    printf 'Created: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '## Operator Intent\n\n'
    printf 'Describe the outcome, scope, acceptance criteria, and read-only lanes.\n\n'
    printf '## Active Lanes\n\n'
    printf '| Lane | Owner | Worktree | Expected branch |\n'
    printf '| --- | --- | --- | --- |\n'
    for lane in $(operator_lanes); do
      printf '| `%s` | %s | `%s` | `%s` |\n' \
        "$lane" \
        "$(operator_lane_owner "$lane")" \
        "$(operator_lane_path "$lane")" \
        "$(operator_lane_branch "$lane")"
    done
    printf '\n## Integration Checklist\n\n'
    printf '%s\n' '- Confirm each lane is on the expected branch before dispatch.'
    printf '%s\n' '- Dispatch scoped task packets from this external `tasks/` folder.'
    printf '%s\n' '- Collect lane handoffs into this external `handoffs/` folder.'
    printf '%s\n' '- Distill durable facts into evergreen repo docs; do not commit raw handoffs.'
    printf '%s\n' '- Review diffs from the operator/main worktree before merging.'
  } > "$brief"
fi

printf '%s\n' "$task_dir"
