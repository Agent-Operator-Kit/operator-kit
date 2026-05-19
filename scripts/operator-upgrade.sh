#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-upgrade.sh [options]

Refreshes Agent Operator Kit everywhere on this machine:
  1. resolve the latest kit source
  2. refresh bundled Codex Desktop skills
  3. discover installed Operator Kit projects
  4. update each installed project
  5. run project checks

Options:
  --source <path|url>       Operator Kit source path or git URL.
  --projects-root <path>    Root to scan for operator.config.env. Repeatable.
                            Defaults to ~/Projects.
  --target <repo>           Update one project repo. Repeatable. Skips scanning.
  --codex-home <path>       Codex home directory. Defaults to $CODEX_HOME or ~/.codex.
  --dry-run                 Show what would change without writing files.
  --no-fetch                Do not pull or clone updates.
  --skip-skills             Do not refresh global Codex Desktop skills.
  --skip-projects           Do not update project repos.
  --skip-checks             Do not run project validation checks.
  -h, --help                Show this help.

Examples:
  bash scripts/operator-upgrade.sh
  bash scripts/operator-upgrade.sh --dry-run
  bash scripts/operator-upgrade.sh --target /path/to/project
  bash scripts/operator-upgrade.sh --projects-root /path/to/projects
  bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LOCAL_SOURCE="$HOME/Projects/Agent-Operator-Kit/operator-kit"
DEFAULT_REMOTE_SOURCE="https://github.com/Agent-Operator-Kit/operator-kit.git"

SOURCE="${OPERATOR_KIT_SOURCE:-}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DRY_RUN=0
NO_FETCH=0
SKIP_SKILLS=0
SKIP_PROJECTS=0
SKIP_CHECKS=0
TMP_ROOT=""
PROJECT_ROOTS=()
TARGETS=()

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --projects-root)
      PROJECT_ROOTS+=("${2:-}")
      shift 2
      ;;
    --target)
      TARGETS+=("${2:-}")
      shift 2
      ;;
    --codex-home)
      CODEX_HOME_DIR="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-fetch)
      NO_FETCH=1
      shift
      ;;
    --skip-skills)
      SKIP_SKILLS=1
      shift
      ;;
    --skip-projects)
      SKIP_PROJECTS=1
      shift
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

print_section() {
  printf '\n## %s\n' "$1"
}

is_kit_source() {
  local path="$1"
  [ -f "$path/scripts/operator-bootstrap.sh" ] && [ -d "$path/skills/codex" ]
}

resolve_default_source() {
  if [ -n "$SOURCE" ]; then
    printf '%s\n' "$SOURCE"
    return 0
  fi

  if is_kit_source "$SCRIPT_ROOT"; then
    printf '%s\n' "$SCRIPT_ROOT"
    return 0
  fi

  if [ -d "$DEFAULT_LOCAL_SOURCE" ] && is_kit_source "$DEFAULT_LOCAL_SOURCE"; then
    printf '%s\n' "$DEFAULT_LOCAL_SOURCE"
    return 0
  fi

  printf '%s\n' "$DEFAULT_REMOTE_SOURCE"
}

prepare_source() {
  SOURCE="$(resolve_default_source)"

  if [ -d "$SOURCE" ]; then
    SOURCE_PATH="$(cd "$SOURCE" && pwd)"
    if [ "$NO_FETCH" -eq 0 ] && git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git -C "$SOURCE_PATH" status --porcelain)" ]; then
        printf 'Source has local changes; skipping git pull: %s\n' "$SOURCE_PATH" >&2
      else
        git -C "$SOURCE_PATH" pull --ff-only >/dev/null
      fi
    fi
  else
    if [ "$NO_FETCH" -eq 1 ]; then
      printf 'Source is not a local directory and --no-fetch was set: %s\n' "$SOURCE" >&2
      exit 1
    fi
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-upgrade.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
  fi

  if ! is_kit_source "$SOURCE_PATH"; then
    printf 'Invalid Operator Kit source: %s\n' "$SOURCE_PATH" >&2
    exit 1
  fi
}

discover_targets() {
  local list_file="$1"
  local root cfg repo

  : > "$list_file"

  if [ "${#TARGETS[@]}" -gt 0 ]; then
    for repo in "${TARGETS[@]}"; do
      [ -n "$repo" ] || continue
      if [ ! -d "$repo" ]; then
        printf 'Target directory does not exist: %s\n' "$repo" >&2
        continue
      fi
      if git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$repo" rev-parse --show-toplevel >> "$list_file"
      else
        printf 'Skipping non-git target: %s\n' "$repo" >&2
      fi
    done
    sort -u "$list_file" -o "$list_file"
    return 0
  fi

  if [ "${#PROJECT_ROOTS[@]}" -eq 0 ]; then
    PROJECT_ROOTS=("$HOME/Projects")
  fi

  for root in "${PROJECT_ROOTS[@]}"; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ]; then
      printf 'Projects root not found, skipping: %s\n' "$root" >&2
      continue
    fi
    while IFS= read -r -d '' cfg; do
      repo="$(dirname "$cfg")"
      if git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$repo" rev-parse --show-toplevel >> "$list_file"
      else
        printf 'Skipping Operator Kit config outside git repo: %s\n' "$cfg" >&2
      fi
    done < <(find "$root" -name operator.config.env -not -path '*/.git/*' -print0)
  done

  sort -u "$list_file" -o "$list_file"
}

prepare_source
SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

print_section "Operator Kit Upgrade"
printf 'Source: %s\n' "$SOURCE_PATH"
printf 'Source revision: %s\n' "$SOURCE_REVISION"
printf 'Codex home: %s\n' "$CODEX_HOME_DIR"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Mode: dry run\n'
fi

if [ "$SKIP_SKILLS" -eq 0 ]; then
  print_section "Codex Desktop Skills"
  skill_args=(--source "$SOURCE_PATH" --codex-home "$CODEX_HOME_DIR" --no-fetch)
  if [ "$DRY_RUN" -eq 1 ]; then
    skill_args+=(--dry-run)
  fi
  bash "$SOURCE_PATH/scripts/codex-skills-install.sh" "${skill_args[@]}"
else
  print_section "Codex Desktop Skills"
  printf 'Skipped.\n'
fi

if [ "$SKIP_PROJECTS" -eq 1 ]; then
  print_section "Project Updates"
  printf 'Skipped.\n'
  print_section "Done"
  printf 'Restart or reopen Codex Desktop so refreshed skills appear in the skill list.\n'
  exit 0
fi

TARGET_LIST="$(mktemp /tmp/operator-kit-upgrade-targets.XXXXXX)"
trap 'rm -f "$TARGET_LIST"; cleanup' EXIT
discover_targets "$TARGET_LIST"

print_section "Project Updates"
if [ ! -s "$TARGET_LIST" ]; then
  printf 'No installed Operator Kit projects found.\n'
  print_section "Done"
  printf 'Restart or reopen Codex Desktop so refreshed skills appear in the skill list.\n'
  exit 0
fi

updated=0
failed=0

while IFS= read -r target; do
  [ -n "$target" ] || continue
  printf '\n### %s\n' "$target"

  sync_args=(--source "$SOURCE_PATH" --target "$target" --skip-skills --no-fetch)
  if [ "$DRY_RUN" -eq 1 ]; then
    sync_args+=(--dry-run)
  fi
  if [ "$SKIP_CHECKS" -eq 1 ]; then
    sync_args+=(--skip-checks)
  fi

  if bash "$SOURCE_PATH/scripts/operator-sync.sh" "${sync_args[@]}"; then
    updated=$((updated + 1))
  else
    failed=$((failed + 1))
  fi
done < "$TARGET_LIST"

print_section "Summary"
printf 'Projects processed: %s\n' "$updated"
printf 'Projects failed: %s\n' "$failed"

print_section "Done"
printf 'Restart or reopen Codex Desktop so refreshed skills appear in the skill list.\n'

if [ "$failed" -gt 0 ]; then
  exit 1
fi
