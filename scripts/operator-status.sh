#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

TMUX_BIN="$(operator_tmux_bin || true)"

printf '%-16s %-18s %-24s %-58s %s\n' lane owner "expected branch" git tmux
printf '%-16s %-18s %-24s %-58s %s\n' ---- ----- "---------------" --- ----

for lane in $(operator_lanes); do
  owner="$(operator_lane_owner "$lane")"
  path="$(operator_lane_path "$lane")"
  expected_branch="$(operator_lane_branch "$lane")"

  git_status="missing"
  if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
    branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"
    [ -n "$branch" ] || branch="detached"
    dirty="clean"
    if [ -n "$(git -C "$path" status --short 2>/dev/null)" ]; then
      dirty="dirty"
    fi
    upstream="$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -n "$upstream" ]; then
      counts="$(git -C "$path" rev-list --left-right --count HEAD..."$upstream" 2>/dev/null || printf '0 0')"
      ahead="$(printf '%s' "$counts" | awk '{print $1}')"
      behind="$(printf '%s' "$counts" | awk '{print $2}')"
      git_status="$branch $upstream behind=$behind,ahead=$ahead $dirty"
    else
      git_status="$branch no-upstream $dirty"
    fi
  fi

  tmux_status="not-running"
  if [ -n "$TMUX_BIN" ] && "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if "$TMUX_BIN" list-windows -t "$TMUX_SESSION" -F '#{window_name}' | grep -Fxq "$lane"; then
      tmux_status="window"
    else
      tmux_status="missing-window"
    fi
  fi

  printf '%-16s %-18s %-24s %-58s %s\n' "$lane" "$owner" "$expected_branch" "$git_status" "$tmux_status"
done
