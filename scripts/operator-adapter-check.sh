#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-adapter-check.sh [--json]

Validate Cursor adapter assets for sticky Operator mode.

Exits 0 when healthy. Exits 1 when required assets are missing or misconfigured.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"

JSON=0
ISSUES=()
WARNINGS=()

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
rule_file="$repo_root/.cursor/rules/operator-workflow.mdc"
operator_skill="$repo_root/.cursor/skills/operator/SKILL.md"
gitignore_file="$repo_root/.gitignore"

check_present() {
  local path="$1"
  local label="$2"
  if [ ! -f "$path" ]; then
    ISSUES+=("missing: $label ($path)")
    return 1
  fi
  return 0
}

check_present "$rule_file" ".cursor/rules/operator-workflow.mdc"
if [ -f "$rule_file" ] && ! grep -q 'Sticky Operator mode' "$rule_file"; then
  ISSUES+=("stale rule: .cursor/rules/operator-workflow.mdc lacks Sticky Operator mode section")
fi

check_present "$operator_skill" ".cursor/skills/operator/SKILL.md"

if [ -f "$gitignore_file" ] && grep -Eq '^operator/' "$gitignore_file"; then
  ISSUES+=("gitignore: use /operator/ (repo-root only) so .cursor/skills/operator/ is not ignored")
fi

if [ -f "$gitignore_file" ] && command -v git >/dev/null 2>&1; then
  if git -C "$repo_root" check-ignore -q .cursor/skills/operator/SKILL.md 2>/dev/null; then
    ISSUES+=("gitignore: .cursor/skills/operator/SKILL.md is ignored by git")
  fi
fi

command_file="$repo_root/.cursor/commands/operator.md"
if [ ! -f "$command_file" ]; then
  WARNINGS+=("optional: .cursor/commands/operator.md not installed ( /operator command )")
fi

if [ "$JSON" -eq 1 ]; then
  printf '{"ok":%s,"issues":[' "$([ "${#ISSUES[@]}" -eq 0 ] && printf true || printf false)"
  i=0
  for issue in "${ISSUES[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    i=$((i + 1))
    printf '"%s"' "${issue//\"/\\\"}"
  done
  printf '],"warnings":['
  i=0
  for warning in "${WARNINGS[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    i=$((i + 1))
    printf '"%s"' "${warning//\"/\\\"}"
  done
  printf ']}\n'
else
  printf 'Cursor adapter check: %s\n' "$PROJECT_NAME"
  printf 'Repo root: %s\n' "$repo_root"
  if [ "${#ISSUES[@]}" -eq 0 ]; then
    printf 'Status: ok\n'
  else
    printf 'Status: needs repair\n'
    printf '\nIssues:\n'
    printf '  - %s\n' "${ISSUES[@]}"
  fi
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\nWarnings:\n'
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    printf '\nRepair:\n'
    printf '  bash scripts/operator-sync.sh --channel latest --target %s --refresh-cursor-adapter\n' "$repo_root"
  fi
fi

[ "${#ISSUES[@]}" -eq 0 ]
