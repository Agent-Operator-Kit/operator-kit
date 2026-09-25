#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-workers.sh <command> [args]

Track background workers (tmux lanes, Cursor Task subagents, Multitask) per task.

Commands:
  register <task-slug> <worker-id> [--kind tmux|task|multitask]
      Record a worker for a task slug. Exits 1 if the same worker-id is already active.
  list <task-slug>
      List registered workers for a task slug.
  check <task-slug> <worker-id>
      Exit 0 when worker-id is not registered; exit 1 when duplicate.
  clear <task-slug> [--worker <id>]
      Remove worker records for a task slug.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"

manifest_for_slug() {
  local slug="$1"
  printf '%s/tasks/%s/workers/manifest.jsonl\n' "$OPERATOR_DIR" "$slug"
}

register_worker() {
  local slug="${1:-}"
  local worker_id="${2:-}"
  local kind="${3:-task}"
  local manifest ts line

  if [ -z "$slug" ] || [ -z "$worker_id" ]; then
    usage >&2
    exit 1
  fi

  manifest="$(manifest_for_slug "$slug")"
  mkdir -p "$(dirname "$manifest")"

  if [ -f "$manifest" ] && grep -Fq "\"id\":\"$worker_id\"" "$manifest"; then
    printf 'Worker already registered for %s: %s\n' "$slug" "$worker_id" >&2
    exit 1
  fi

  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  line="{\"id\":\"$worker_id\",\"kind\":\"$kind\",\"registeredAt\":\"$ts\"}"
  printf '%s\n' "$line" >> "$manifest"
  printf 'Registered worker %s (%s) for task %s\n' "$worker_id" "$kind" "$slug"
  printf 'Manifest: %s\n' "$manifest"
}

list_workers() {
  local slug="${1:-}"
  local manifest

  if [ -z "$slug" ]; then
    usage >&2
    exit 1
  fi

  manifest="$(manifest_for_slug "$slug")"
  printf 'Task: %s\n' "$slug"
  if [ ! -f "$manifest" ]; then
    printf 'Workers: none\n'
    return 0
  fi
  printf 'Workers:\n'
  sed 's/^/  /' "$manifest"
}

check_worker() {
  local slug="${1:-}"
  local worker_id="${2:-}"
  local manifest

  if [ -z "$slug" ] || [ -z "$worker_id" ]; then
    usage >&2
    exit 1
  fi

  manifest="$(manifest_for_slug "$slug")"
  if [ -f "$manifest" ] && grep -Fq "\"id\":\"$worker_id\"" "$manifest"; then
    exit 1
  fi
}

clear_workers() {
  local slug="${1:-}"
  local worker_id=""
  local manifest tmp

  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worker) worker_id="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$slug" ]; then
    usage >&2
    exit 1
  fi

  manifest="$(manifest_for_slug "$slug")"
  if [ ! -f "$manifest" ]; then
    printf 'No workers registered for %s\n' "$slug"
    return 0
  fi

  if [ -z "$worker_id" ]; then
    rm -f "$manifest"
    printf 'Cleared workers for %s\n' "$slug"
    return 0
  fi

  tmp="$(mktemp)"
  grep -Fv "\"id\":\"$worker_id\"" "$manifest" > "$tmp" || true
  if [ -s "$tmp" ]; then
    mv "$tmp" "$manifest"
  else
    rm -f "$manifest" "$tmp"
  fi
  printf 'Removed worker %s from %s\n' "$worker_id" "$slug"
}

operator_load_config

command="${1:-}"
shift || true

case "$command" in
  register)
    kind="task"
    slug="${1:-}"
    worker_id="${2:-}"
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) kind="${2:-}"; shift 2 ;;
        *)
          printf 'Unknown option: %s\n' "$1" >&2
          exit 1
          ;;
      esac
    done
    register_worker "$slug" "$worker_id" "$kind"
    ;;
  list) list_workers "${1:-}" ;;
  check) check_worker "${1:-}" "${2:-}" ;;
  clear) clear_workers "$@" ;;
  -h|--help|"") usage ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
