#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-tmux.sh <command> [lane]

Commands:
  start          Create tmux session/windows for all lanes
  attach [lane]  Attach to the session or a lane
  start-workers  Start configured agent commands in non-operator lanes
  stop           Stop the tmux session
USAGE
}

cmd="${1:-}"
lane_arg="${2:-}"

TMUX_BIN="$(operator_tmux_bin || true)"
if [ -z "$TMUX_BIN" ]; then
  printf 'tmux is not installed.\n' >&2
  exit 1
fi

ensure_windows() {
  local first_lane lane path
  first_lane="$(operator_lanes | head -1)"
  if ! "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
    path="$(operator_lane_path "$first_lane")"
    mkdir -p "$path"
    "$TMUX_BIN" new-session -d -s "$TMUX_SESSION" -n "$first_lane" -c "$path"
  fi

  for lane in $(operator_lanes); do
    path="$(operator_lane_path "$lane")"
    mkdir -p "$path"
    if ! "$TMUX_BIN" list-windows -t "$TMUX_SESSION" -F '#{window_name}' | grep -Fxq "$lane"; then
      "$TMUX_BIN" new-window -t "$TMUX_SESSION" -n "$lane" -c "$path"
    fi
  done
}

case "$cmd" in
  start)
    ensure_windows
    printf 'tmux session ready: %s\n' "$TMUX_SESSION"
    ;;
  attach)
    ensure_windows
    if [ -n "$lane_arg" ]; then
      operator_require_lane "$lane_arg"
      exec "$TMUX_BIN" attach -t "$TMUX_SESSION:$lane_arg"
    fi
    exec "$TMUX_BIN" attach -t "$TMUX_SESSION"
    ;;
  start-workers)
    ensure_windows
    for lane in $(operator_lanes); do
      invocation="$(operator_lane_invocation "$lane" || true)"
      [ -n "$invocation" ] || continue
      "$TMUX_BIN" send-keys -t "$TMUX_SESSION:$lane.0" "$invocation" Enter
    done
    printf 'worker commands sent to configured lanes\n'
    ;;
  stop)
    "$TMUX_BIN" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    printf 'tmux session stopped: %s\n' "$TMUX_SESSION"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
