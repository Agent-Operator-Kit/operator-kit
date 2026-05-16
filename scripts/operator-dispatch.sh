#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-dispatch.sh [--no-enter] [--with-memory] <lane> <task-file>

Pastes a task packet into the lane's tmux window.

Options:
  --no-enter      Paste the packet without pressing Enter.
  --with-memory   Prepend a retrieved Operator Memory context pack.
USAGE
}

send_enter=1
with_memory=0
args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-enter)
      send_enter=0
      shift
      ;;
    --with-memory)
      with_memory=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    -*)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

lane="${args[0]:-}"
task_file="${args[1]:-}"

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
memory_pack="$(mktemp)"
trap 'rm -f "$payload" "$memory_pack"' EXIT

task_abs="$(cd "$(dirname "$task_file")" && pwd)/$(basename "$task_file")"
slug=""
case "$task_abs" in
  "$OPERATOR_DIR"/tasks/*/tasks/*)
    task_rel="${task_abs#"$OPERATOR_DIR"/tasks/}"
    slug="${task_rel%%/*}"
    ;;
esac

if [ "$with_memory" -eq 1 ]; then
  if [ -z "$slug" ]; then
    printf 'Could not infer task slug from task file; dispatching without memory pack: %s\n' "$task_file" >&2
  elif [ ! -f "$SCRIPT_DIR/operator-memory.sh" ]; then
    printf 'operator-memory.sh not found; dispatching without memory pack.\n' >&2
  elif ! bash "$SCRIPT_DIR/operator-memory.sh" pack "$lane" "$slug" --task-file "$task_file" > "$memory_pack"; then
    printf 'Failed to build memory pack; dispatching task packet only.\n' >&2
    : > "$memory_pack"
  fi
fi

if [ -s "$memory_pack" ]; then
  {
    printf 'Please execute this operator task packet. Use the context pack as retrieved memory.\n\n'
    cat "$memory_pack"
    printf '\n\n---\n\n'
    printf '# Operator Task Packet\n\n'
    cat "$task_file"
  } > "$payload"
else
  {
    printf 'Please execute this operator task packet.\n\n'
    cat "$task_file"
  } > "$payload"
fi

"$TMUX_BIN" load-buffer "$payload"
"$TMUX_BIN" paste-buffer -t "$TMUX_SESSION:$lane.0"

if [ "$send_enter" -eq 1 ]; then
  "$TMUX_BIN" send-keys -t "$TMUX_SESSION:$lane.0" Enter
fi

if [ -s "$memory_pack" ]; then
  printf 'dispatched %s to %s:%s with memory pack\n' "$task_file" "$TMUX_SESSION" "$lane"
else
  printf 'dispatched %s to %s:%s\n' "$task_file" "$TMUX_SESSION" "$lane"
fi
