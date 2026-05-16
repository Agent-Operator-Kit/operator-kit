#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-sync.sh [options]

Single-command sync for Agent Operator Kit:
  1. resolve the latest kit source
  2. install or refresh bundled Codex Desktop skills
  3. detect the current Operator Kit project
  4. update the project from the kit source
  5. run status checks

Options:
  --source <path|url>       Operator Kit source path or git URL.
  --target <repo>           Project repo to update. Defaults to auto-detect.
  --codex-home <path>       Codex home directory. Defaults to $CODEX_HOME or ~/.codex.
  --dry-run                 Show what would change without writing files.
  --no-fetch                Do not pull or clone updates.
  --skip-skills             Do not refresh global Codex Desktop skills.
  --skip-project            Do not update a project repo.
  --skip-checks             Do not run project validation checks.
  --bootstrap-if-missing    Bootstrap target repo if operator.config.env is missing.
  -h, --help                Show this help.

Examples:
  bash scripts/operator-sync.sh
  bash scripts/operator-sync.sh --target /path/to/project
  bash /path/to/operator-kit/scripts/operator-sync.sh --target "$PWD"
  bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LOCAL_SOURCE="$HOME/Projects/Agent-Operator-Kit/operator-kit"
DEFAULT_REMOTE_SOURCE="https://github.com/Agent-Operator-Kit/operator-kit.git"

SOURCE="${OPERATOR_KIT_SOURCE:-}"
TARGET_REPO=""
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DRY_RUN=0
NO_FETCH=0
SKIP_SKILLS=0
SKIP_PROJECT=0
SKIP_CHECKS=0
BOOTSTRAP_IF_MISSING=0
TMP_ROOT=""

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
    --target)
      TARGET_REPO="${2:-}"
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
    --skip-project)
      SKIP_PROJECT=1
      shift
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      shift
      ;;
    --bootstrap-if-missing)
      BOOTSTRAP_IF_MISSING=1
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
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-sync.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
  fi

  if ! is_kit_source "$SOURCE_PATH"; then
    printf 'Invalid Operator Kit source: %s\n' "$SOURCE_PATH" >&2
    exit 1
  fi
}

find_upward_config() {
  local start="$1"
  local dir
  dir="$(cd "$start" 2>/dev/null && pwd || true)"

  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/operator.config.env" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

find_sibling_config() {
  local start="$1"
  local dir
  local candidate
  local matches=()
  dir="$(cd "$start" 2>/dev/null && pwd || true)"

  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$HOME" ]; do
    for candidate in "$dir"/*; do
      [ -d "$candidate" ] || continue
      if [ -f "$candidate/operator.config.env" ]; then
        matches+=("$(cd "$candidate" && pwd)")
      fi
    done
    if [ "${#matches[@]}" -gt 0 ]; then
      break
    fi
    dir="$(dirname "$dir")"
  done

  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [ "${#matches[@]}" -gt 1 ]; then
    printf 'Multiple Operator Kit project roots detected. Re-run with --target:\n' >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 2
  fi

  return 1
}

detect_target_repo() {
  local start="$1"
  local detected=""
  local git_root=""
  local sibling_status=0

  if [ -n "$TARGET_REPO" ]; then
    if [ ! -d "$TARGET_REPO" ]; then
      printf 'Target directory does not exist: %s\n' "$TARGET_REPO" >&2
      exit 1
    fi
    git -C "$TARGET_REPO" rev-parse --show-toplevel 2>/dev/null || {
      printf 'Target is not a git repository: %s\n' "$TARGET_REPO" >&2
      exit 1
    }
    return 0
  fi

  detected="$(find_upward_config "$start" || true)"
  if [ -n "$detected" ]; then
    printf '%s\n' "$detected"
    return 0
  fi

  if detected="$(find_sibling_config "$start")"; then
    printf '%s\n' "$detected"
    return 0
  else
    sibling_status=$?
    if [ "$sibling_status" -eq 2 ]; then
      exit 1
    fi
  fi

  git_root="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_root" ]; then
    printf '%s\n' "$git_root"
    return 0
  fi

  return 1
}

run_project_checks() {
  local target="$1"

  print_section "Project Checks"
  (
    cd "$target"
    bash -n scripts/*.sh
    bash scripts/operator-status.sh
    bash scripts/operator-summary.sh
    bash scripts/operator-memory.sh status
    git status --short
  )
}

prepare_source
SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

print_section "Operator Kit Sync"
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

if [ "$SKIP_PROJECT" -eq 1 ]; then
  print_section "Project Update"
  printf 'Skipped.\n'
  exit 0
fi

TARGET_DETECTED="$(detect_target_repo "$PWD" || true)"
if [ -z "$TARGET_DETECTED" ]; then
  print_section "Project Update"
  printf 'No git project detected from: %s\n' "$PWD"
  printf 'Codex skills were refreshed. Re-run with --target /path/to/project to update a project repo.\n'
  exit 0
fi

TARGET_REPO="$(git -C "$TARGET_DETECTED" rev-parse --show-toplevel)"

print_section "Project Detection"
printf 'Target: %s\n' "$TARGET_REPO"

if [ ! -f "$TARGET_REPO/operator.config.env" ]; then
  if [ "$BOOTSTRAP_IF_MISSING" -eq 1 ]; then
    print_section "Project Bootstrap"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'Would bootstrap Operator Kit into: %s\n' "$TARGET_REPO"
      exit 0
    fi
    bash "$SOURCE_PATH/scripts/operator-bootstrap.sh" "$TARGET_REPO"
  else
    print_section "Project Update"
    printf 'Target is a git repo but does not look like an installed Operator Kit project.\n'
    printf 'Missing: operator.config.env\n'
    printf 'To bootstrap intentionally, run:\n'
    printf '  bash %s/scripts/operator-sync.sh --target %s --bootstrap-if-missing\n' "$SOURCE_PATH" "$TARGET_REPO"
    exit 0
  fi
fi

print_section "Project Update"
update_args=(--source "$SOURCE_PATH" --target "$TARGET_REPO" --no-fetch)
if [ "$DRY_RUN" -eq 1 ]; then
  update_args+=(--dry-run)
fi
bash "$SOURCE_PATH/scripts/operator-update.sh" "${update_args[@]}"

if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_CHECKS" -eq 0 ]; then
  run_project_checks "$TARGET_REPO"
else
  print_section "Project Checks"
  printf 'Skipped.\n'
fi

print_section "Done"
printf 'Restart or reopen Codex Desktop so refreshed skills appear in the skill list.\n'
