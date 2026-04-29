#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

send_enter=1
if [ "${1:-}" = "--no-enter" ]; then
  send_enter=0
  shift
fi

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-dispatch.sh [--no-enter] <lane> <task-file>

Pastes a task packet into the lane's tmux window.
USAGE
}

lane="${1:-}"
task_file="${2:-}"

if [ -z "$lane" ] || [ -z "$task_file" ]; then
  usage >&2
  exit 1
fi

operator_require_lane "$lane"

if [ ! -f "$task_file" ]; then
  printf 'Task file not found: %s\n' "$task_file" >&2
  exit 1
fi

TMUX_BIN="$(operator_tmux_bin || true)"
if [ -z "$TMUX_BIN" ]; then
  printf 'tmux is not installed.\n' >&2
  exit 1
fi

if ! "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  printf 'tmux session not running: %s\n' "$TMUX_SESSION" >&2
  exit 1
fi

if ! "$TMUX_BIN" list-windows -t "$TMUX_SESSION" -F '#{window_name}' | grep -Fxq "$lane"; then
  printf 'tmux lane window not found: %s\n' "$lane" >&2
  exit 1
fi

payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT
{
  printf 'Please execute this operator task packet.\n\n'
  cat "$task_file"
} > "$payload"

"$TMUX_BIN" load-buffer "$payload"
"$TMUX_BIN" paste-buffer -t "$TMUX_SESSION:$lane.0"

if [ "$send_enter" -eq 1 ]; then
  "$TMUX_BIN" send-keys -t "$TMUX_SESSION:$lane.0" Enter
fi

printf 'dispatched %s to %s:%s\n' "$task_file" "$TMUX_SESSION" "$lane"
