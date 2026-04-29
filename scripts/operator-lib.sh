#!/usr/bin/env bash

# Shared helpers for Agent Operator Kit scripts.

operator_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

operator_config_file() {
  printf '%s\n' "${OPERATOR_CONFIG:-$(pwd)/operator.config.env}"
}

operator_load_config() {
  local config_file="${1:-$(operator_config_file)}"
  if [ ! -f "$config_file" ]; then
    printf 'Missing operator config: %s\n' "$config_file" >&2
    printf 'Run: bash scripts/operator-bootstrap.sh /path/to/repo\n' >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$config_file"

  : "${PROJECT_NAME:?PROJECT_NAME is required}"
  : "${PROJECT_ROOT:?PROJECT_ROOT is required}"
  : "${CODE_DIR:?CODE_DIR is required}"
  : "${OPERATOR_DIR:?OPERATOR_DIR is required}"
  : "${TMUX_SESSION:?TMUX_SESSION is required}"
  : "${DEFAULT_BRANCH:=main}"
  : "${OPERATOR_LANES:?OPERATOR_LANES is required}"
}

operator_lanes() {
  printf '%s\n' "$OPERATOR_LANES" | awk -F'|' 'NF >= 4 && $1 !~ /^[[:space:]]*$/ { print $1 }'
}

operator_lane_row() {
  local lane="$1"
  printf '%s\n' "$OPERATOR_LANES" | awk -F'|' -v lane="$lane" 'NF >= 4 && $1 == lane { print; exit }'
}

operator_lane_field() {
  local lane="$1"
  local field="$2"
  local row
  row="$(operator_lane_row "$lane")"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row" | awk -F'|' -v field="$field" '{ print $field }'
}

operator_lane_owner() {
  operator_lane_field "$1" 2
}

operator_lane_worktree_name() {
  operator_lane_field "$1" 3
}

operator_lane_branch() {
  operator_lane_field "$1" 4
}

operator_lane_invocation() {
  operator_lane_field "$1" 5
}

operator_lane_path() {
  local worktree_name
  worktree_name="$(operator_lane_worktree_name "$1")"
  printf '%s\n' "$CODE_DIR/$worktree_name"
}

operator_lane_exists() {
  local lane="$1"
  [ -n "$(operator_lane_row "$lane")" ]
}

operator_require_lane() {
  local lane="${1:-}"
  if ! operator_lane_exists "$lane"; then
    printf 'Unknown lane: %s\n' "$lane" >&2
    printf 'Valid lanes:\n' >&2
    operator_lanes >&2
    return 1
  fi
}

operator_tmux_bin() {
  if command -v tmux >/dev/null 2>&1; then
    command -v tmux
    return 0
  fi

  if [ -x /opt/homebrew/bin/tmux ]; then
    printf '%s\n' /opt/homebrew/bin/tmux
    return 0
  fi

  return 1
}
