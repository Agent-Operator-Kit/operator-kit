#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-context.sh [--json]

Print the current Operator Kit workspace context: project, worktree, branch,
lane match, and discoverable operator configs.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"

JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

operator_load_config

repo_root="$(operator_repo_root)"
cwd="$(pwd -P)"
matched_lane=""
matched_path=""

for lane in $(operator_lanes); do
  path="$(operator_lane_path "$lane")"
  if [ ! -d "$path" ]; then
    continue
  fi
  resolved="$(cd "$path" && pwd -P)"
  if [ "$cwd" = "$resolved" ] || [[ "$cwd" == "$resolved"/* ]]; then
    matched_lane="$lane"
    matched_path="$resolved"
    break
  fi
done

branch="n/a"
if [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || printf detached)"
fi

config_candidates=()
search_root="$PROJECT_ROOT"
if [ -d "$search_root/code" ]; then
  while IFS= read -r cfg; do
    [ -n "$cfg" ] && config_candidates+=("$cfg")
  done < <(find "$search_root/code" -maxdepth 2 -name operator.config.env 2>/dev/null | sort)
fi
if [ "${#config_candidates[@]}" -eq 0 ] && [ -f "$repo_root/operator.config.env" ]; then
  config_candidates+=("$repo_root/operator.config.env")
fi

feature_line="none"
if [ -f "$SCRIPT_DIR/operator-feature.sh" ]; then
  feature_line="$(bash "$SCRIPT_DIR/operator-feature.sh" current --tool cursor 2>/dev/null | head -1 || printf none)"
fi

if [ "${#config_candidates[@]}" -gt 1 ] && [ -z "${OPERATOR_CONFIG:-}" ]; then
  printf 'Multiple operator configs detected; set OPERATOR_CONFIG to one project root.\n' >&2
  printf '  - %s\n' "${config_candidates[@]}" >&2
  exit 2
fi

if [ "$JSON" -eq 1 ]; then
  printf '{"project":"%s","operator_dir":"%s","repo_root":"%s","cwd":"%s","branch":"%s","matched_lane":"%s","matched_worktree":"%s","operator_config":"%s","config_candidates":%s,"feature_binding":"%s"}\n' \
    "$PROJECT_NAME" "$OPERATOR_DIR" "$repo_root" "$cwd" "$branch" "$matched_lane" "$matched_path" \
    "$(operator_config_file)" \
    "$(printf '%s\n' "${config_candidates[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" \
    "$feature_line"
else
  printf 'Project: %s\n' "$PROJECT_NAME"
  printf 'Operator workspace: %s\n' "$OPERATOR_DIR"
  printf 'Bound config: %s\n' "$(operator_config_file)"
  printf 'Repo root (this install): %s\n' "$repo_root"
  printf 'Current directory: %s\n' "$cwd"
  printf 'Git branch (cwd): %s\n' "$branch"
  if [ -n "$matched_lane" ]; then
    printf 'Matched lane: %s (%s)\n' "$matched_lane" "$matched_path"
  else
    printf 'Matched lane: none (cwd is outside configured lane worktrees)\n'
  fi
  if [ -f "$SCRIPT_DIR/operator-feature.sh" ]; then
    printf '\nFeature binding (cursor):\n'
    bash "$SCRIPT_DIR/operator-feature.sh" current --tool cursor 2>/dev/null || printf '  none\n'
  fi
fi
