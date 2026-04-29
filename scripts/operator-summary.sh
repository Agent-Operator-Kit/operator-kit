#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

TMUX_BIN="$(operator_tmux_bin || true)"

print_section() {
  printf '\n## %s\n' "$1"
}

latest_handoff() {
  local lane="$1"
  find "$OPERATOR_DIR/tasks" -path "*/handoffs/${lane}-capture-*.md" -type f 2>/dev/null \
    | sort \
    | tail -1
}

summarize_stream() {
  awk '
    BEGIN { count = 0 }
    {
      line = $0
      gsub(/\r/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^```/) next
      if (line ~ /(Handoff|Result|Status|Changed files|Commands run|Blockers?|failed|passed|completed|Done|Next|Recommended|Follow-up|Working|Running|Waiting|Validation|clean|dirty|merge|dispatch)/) {
        lines[++count] = line
      }
    }
    END {
      start = count - 11
      if (start < 1) start = 1
      for (i = start; i <= count; i++) print "  - " lines[i]
    }
  '
}

print_section "Operator Summary"
printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'Project: %s\n' "$PROJECT_NAME"
printf 'Operator workspace: %s\n' "$OPERATOR_DIR"

print_section "Lane Health"
bash "$SCRIPT_DIR/operator-status.sh"

print_section "Lane Details"
for lane in $(operator_lanes); do
  path="$(operator_lane_path "$lane")"
  printf '\n### %s\n' "$lane"
  printf 'Worktree: %s\n' "$path"

  if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
    printf 'Branch: %s\n' "$(git -C "$path" branch --show-current 2>/dev/null || printf detached)"
    dirty="$(git -C "$path" status --short 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
      printf 'Dirty files:\n%s\n' "$(printf '%s\n' "$dirty" | sed 's/^/  /')"
    else
      printf 'Dirty files: none\n'
    fi
  else
    printf 'Git: missing\n'
  fi

  if [ -n "$TMUX_BIN" ] && "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null && "$TMUX_BIN" list-windows -t "$TMUX_SESSION" -F '#{window_name}' | grep -Fxq "$lane"; then
    printf 'Current pane highlights:\n'
    "$TMUX_BIN" capture-pane -p -S -220 -t "$TMUX_SESSION:$lane.0" | summarize_stream | sed '/^$/d' || true
  else
    printf 'Current pane highlights: unavailable\n'
  fi

  handoff="$(latest_handoff "$lane")"
  if [ -n "$handoff" ]; then
    printf 'Latest handoff: %s\n' "${handoff#$OPERATOR_DIR/}"
    printf 'Latest handoff highlights:\n'
    summarize_stream < "$handoff" | sed '/^$/d' || true
  else
    printf 'Latest handoff: none\n'
  fi
done

print_section "Recent Task Folders"
find "$OPERATOR_DIR/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
  | sort \
  | tail -8 \
  | sed "s#^$OPERATOR_DIR/##" \
  | sed 's/^/  - /'
