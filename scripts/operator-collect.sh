#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-collect.sh <lane> <slug>

Captures the lane tmux pane into $OPERATOR_DIR/tasks/<slug>/handoffs/.
USAGE
}

lane="${1:-}"
slug="${2:-}"

if [ -z "$lane" ] || [ -z "$slug" ]; then
  usage >&2
  exit 1
fi

operator_require_lane "$lane"

TMUX_BIN="$(operator_tmux_bin || true)"
if [ -z "$TMUX_BIN" ]; then
  printf 'tmux is not installed.\n' >&2
  exit 1
fi

if ! "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  printf 'tmux session not running: %s\n' "$TMUX_SESSION" >&2
  exit 1
fi

handoff_dir="$OPERATOR_DIR/tasks/$slug/handoffs"
mkdir -p "$handoff_dir"

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
output_file="$handoff_dir/${lane}-capture-${timestamp}.md"

{
  printf '# %s Capture\n\n' "$lane"
  printf 'Captured: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' "- Lane: \`$lane\`"
  printf '%s\n' "- Owner: $(operator_lane_owner "$lane")"
  printf '%s\n' "- Worktree: \`$(operator_lane_path "$lane")\`"
  printf '%s\n\n' "- Expected branch: \`$(operator_lane_branch "$lane")\`"
  printf '```text\n'
  "$TMUX_BIN" capture-pane -p -S -2000 -t "$TMUX_SESSION:$lane.0"
  printf '```\n'
} > "$output_file"

printf '%s\n' "$output_file"
