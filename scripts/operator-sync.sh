#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-sync.sh [options]

Single-command sync for Agent Operator Kit:
  1. resolve the latest kit source
  2. install or refresh bundled global host skills
  3. detect the current Operator Kit project
  4. update the project from the kit source
  5. run status checks

Options:
  --source <path|url>       Operator Kit source path or git URL.
  --channel <name>          Source channel when cloning remote source.
                            Valid channels: stable, v2.1, v3, latest.
  --target <repo>           Project repo to update. Defaults to auto-detect.
  --codex-home <path>       Codex home directory. Defaults to $CODEX_HOME or ~/.codex.
  --cursor-home <path>      Cursor home directory. Defaults to $CURSOR_HOME or ~/.cursor.
  --dry-run                 Show what would change without writing files.
  --no-fetch                Do not pull or clone updates.
  --skip-skills             Do not refresh global host skills.
  --skip-project            Do not update a project repo.
  --skip-checks             Do not run project validation checks.
  --bootstrap-if-missing    Bootstrap target repo if operator.config.env is missing.
  --bootstrap-profile <name> Profile to use with --bootstrap-if-missing.
                            Valid profiles: default, cursor.
  -h, --help                Show this help.

Examples:
  bash scripts/operator-sync.sh
  bash scripts/operator-sync.sh --target /path/to/project
  bash scripts/operator-sync.sh --channel stable --target /path/to/project
  bash scripts/operator-sync.sh --channel v3 --target /path/to/project
  bash scripts/operator-sync.sh --channel latest --target /path/to/project
  bash scripts/operator-sync.sh --target /path/to/empty-project-root --bootstrap-if-missing
  bash scripts/operator-sync.sh --target /path/to/project --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
  bash /path/to/operator-kit/scripts/operator-sync.sh --target "$PWD"
  bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIGINAL_SCRIPT_ROOT="${OPERATOR_SYNC_ORIGINAL_SCRIPT_ROOT:-$SCRIPT_ROOT}"
DEFAULT_LOCAL_SOURCE="$HOME/Projects/Agent-Operator-Kit/operator-kit"
DEFAULT_REMOTE_SOURCE="https://github.com/Agent-Operator-Kit/operator-kit.git"

SOURCE="${OPERATOR_KIT_SOURCE:-}"
CHANNEL="${OPERATOR_KIT_CHANNEL:-stable}"
SOURCE_REF=""
TARGET_REPO=""
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"
DRY_RUN=0
NO_FETCH=0
SKIP_SKILLS=0
SKIP_PROJECT=0
SKIP_CHECKS=0
BOOTSTRAP_IF_MISSING=0
BOOTSTRAP_PROFILE="${OPERATOR_BOOTSTRAP_PROFILE:-default}"
TMP_ROOT=""
TEMP_EXEC_SCRIPT="${OPERATOR_SYNC_TEMP_SCRIPT:-}"

if [ "${OPERATOR_SYNC_TEMP_EXEC:-0}" != "1" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  TEMP_EXEC_SCRIPT="$(mktemp /tmp/operator-sync-run.XXXXXX)"
  cp "${BASH_SOURCE[0]}" "$TEMP_EXEC_SCRIPT"
  chmod +x "$TEMP_EXEC_SCRIPT"
  OPERATOR_SYNC_TEMP_EXEC=1 \
    OPERATOR_SYNC_ORIGINAL_SCRIPT_ROOT="$SCRIPT_ROOT" \
    OPERATOR_SYNC_TEMP_SCRIPT="$TEMP_EXEC_SCRIPT" \
    exec bash "$TEMP_EXEC_SCRIPT" "$@"
fi

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "$TEMP_EXEC_SCRIPT" ] && [ -f "$TEMP_EXEC_SCRIPT" ]; then
    rm -f "$TEMP_EXEC_SCRIPT"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --channel)
      CHANNEL="${2:-}"
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
    --cursor-home)
      CURSOR_HOME_DIR="${2:-}"
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
    --bootstrap-profile)
      BOOTSTRAP_PROFILE="${2:-}"
      shift 2
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

case "$BOOTSTRAP_PROFILE" in
  default|cursor) ;;
  *)
    printf 'Unknown bootstrap profile: %s\n' "$BOOTSTRAP_PROFILE" >&2
    printf 'Valid profiles: default, cursor\n' >&2
    exit 1
    ;;
esac

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

  if is_kit_source "$ORIGINAL_SCRIPT_ROOT"; then
    printf '%s\n' "$ORIGINAL_SCRIPT_ROOT"
    return 0
  fi

  if [ -d "$DEFAULT_LOCAL_SOURCE" ] && is_kit_source "$DEFAULT_LOCAL_SOURCE"; then
    printf '%s\n' "$DEFAULT_LOCAL_SOURCE"
    return 0
  fi

  printf '%s\n' "$DEFAULT_REMOTE_SOURCE"
}

prepare_source() {
  case "$CHANNEL" in
    stable|v2.1) SOURCE_REF="v2.1" ;;
    v3) SOURCE_REF="v3" ;;
    latest|main) SOURCE_REF="" ;;
    *)
      printf 'Unknown channel: %s\n' "$CHANNEL" >&2
      printf 'Valid channels: stable, v2.1, v3, latest\n' >&2
      exit 1
      ;;
  esac

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
    if [ -n "$SOURCE_REF" ]; then
      if ! git -C "$SOURCE_PATH" rev-parse --verify "$SOURCE_REF" >/dev/null 2>&1; then
        printf 'Source does not contain requested channel ref: %s\n' "$SOURCE_REF" >&2
        exit 1
      fi
      TMP_ROOT="$(mktemp -d /tmp/operator-kit-sync.XXXXXX)"
      mkdir -p "$TMP_ROOT/operator-kit"
      git -C "$SOURCE_PATH" archive "$SOURCE_REF" | tar -x -C "$TMP_ROOT/operator-kit"
      SOURCE_PATH="$TMP_ROOT/operator-kit"
    fi
  else
    if [ "$NO_FETCH" -eq 1 ]; then
      printf 'Source is not a local directory and --no-fetch was set: %s\n' "$SOURCE" >&2
      exit 1
    fi
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-sync.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
    if [ -n "$SOURCE_REF" ]; then
      git -C "$SOURCE_PATH" fetch --depth 1 origin "refs/tags/$SOURCE_REF:refs/tags/$SOURCE_REF" >/dev/null 2>&1 || true
      git -C "$SOURCE_PATH" checkout "$SOURCE_REF" >/dev/null
    fi
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

find_code_config() {
  local start="$1"
  local dir
  local cfg
  local matches=()
  dir="$(cd "$start" 2>/dev/null && pwd || true)"

  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$HOME" ]; do
    if [ -d "$dir/code" ]; then
      for cfg in "$dir"/code/*/operator.config.env; do
        [ -f "$cfg" ] || continue
        matches+=("$(cd "$(dirname "$cfg")" && pwd)")
      done
      if [ "${#matches[@]}" -gt 0 ]; then
        break
      fi
    fi
    dir="$(dirname "$dir")"
  done

  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [ "${#matches[@]}" -gt 1 ]; then
    printf 'Multiple Operator Kit project roots detected under code/. Re-run with --target:\n' >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 2
  fi

  return 1
}

print_scoped_layout() {
  local root="$1"
  cat <<EOF
Recommended scoped Operator Kit layout:
  $root/
    code/
      app/             canonical repo worktree
      app-backend/     optional permanent backend lane
      app-ui/          optional permanent UI lane
    operator/          tasks, handoffs, memory, roadmap, catalog
EOF
}

bootstrap_repo_from_project_root() {
  local root="$1"
  local repo
  root="$(cd "$root" && pwd)"
  repo="$root/code/app"

  print_scoped_layout "$root" >&2

  mkdir -p "$repo"
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo" init >/dev/null
    git -C "$repo" symbolic-ref HEAD refs/heads/main >/dev/null
  fi

  printf '%s\n' "$repo"
}

detect_target_repo() {
  local start="$1"
  local detected=""
  local git_root=""
  local sibling_status=0
  local code_status=0

  if [ -n "$TARGET_REPO" ]; then
    if [ ! -d "$TARGET_REPO" ]; then
      printf 'Target directory does not exist: %s\n' "$TARGET_REPO" >&2
      exit 1
    fi

    git_root="$(git -C "$TARGET_REPO" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$git_root" ]; then
      printf '%s\n' "$git_root"
      return 0
    fi

    if detected="$(find_code_config "$TARGET_REPO")"; then
      printf '%s\n' "$detected"
      return 0
    else
      code_status=$?
      if [ "$code_status" -eq 2 ]; then
        exit 1
      fi
    fi

    if [ "$BOOTSTRAP_IF_MISSING" -eq 1 ]; then
      bootstrap_repo_from_project_root "$TARGET_REPO"
      return 0
    fi

    printf 'Target is not a git repository and no code/*/operator.config.env was found: %s\n' "$TARGET_REPO" >&2
    print_scoped_layout "$(cd "$TARGET_REPO" && pwd)" >&2
    printf 'To bootstrap this as an empty scoped project root, run:\n' >&2
    printf '  bash %s/scripts/operator-sync.sh --target %s --bootstrap-if-missing\n' "$SOURCE_PATH" "$TARGET_REPO" >&2
    exit 1
  fi

  if [ "$BOOTSTRAP_IF_MISSING" -eq 1 ] && ! git -C "$start" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if detected="$(find_code_config "$start")"; then
      printf '%s\n' "$detected"
      return 0
    else
      code_status=$?
      if [ "$code_status" -eq 2 ]; then
        exit 1
      fi
    fi
    bootstrap_repo_from_project_root "$start"
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

  if detected="$(find_code_config "$start")"; then
    printf '%s\n' "$detected"
    return 0
  else
    code_status=$?
    if [ "$code_status" -eq 2 ]; then
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
    bash scripts/operator-roadmap.sh status
    if [ -f scripts/operator-feature.sh ]; then
      bash scripts/operator-feature.sh active
    fi
    if [ -f scripts/operator-conflicts.sh ]; then
      bash scripts/operator-conflicts.sh summary
    fi
    bash scripts/operator-catalog.sh list roles >/dev/null
    bash scripts/operator-recommend-lanes.sh >/dev/null
    bash scripts/operator-plan-batch.sh >/dev/null
    git status --short
  )
}

prepare_source
SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

print_section "Operator Kit Sync"
printf 'Source: %s\n' "$SOURCE_PATH"
printf 'Source revision: %s\n' "$SOURCE_REVISION"
printf 'Channel: %s\n' "$CHANNEL"
printf 'Default kit version: 4\n'
printf 'Codex home: %s\n' "$CODEX_HOME_DIR"
printf 'Cursor home: %s\n' "$CURSOR_HOME_DIR"
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

  print_section "Cursor Skills"
  cursor_skill_args=(--source "$SOURCE_PATH" --cursor-home "$CURSOR_HOME_DIR" --no-fetch)
  if [ "$DRY_RUN" -eq 1 ]; then
    cursor_skill_args+=(--dry-run)
  fi
  if [ -f "$SOURCE_PATH/scripts/cursor-skills-install.sh" ]; then
    bash "$SOURCE_PATH/scripts/cursor-skills-install.sh" "${cursor_skill_args[@]}"
  else
    printf 'Skipped; scripts/cursor-skills-install.sh is unavailable in this source channel.\n'
  fi
else
  print_section "Codex Desktop Skills"
  printf 'Skipped.\n'
  print_section "Cursor Skills"
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
  printf 'Global host skills were refreshed. Re-run with --target /path/to/project to update a project repo.\n'
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
      printf 'Bootstrap profile: %s\n' "$BOOTSTRAP_PROFILE"
      exit 0
    fi
    bash "$SOURCE_PATH/scripts/operator-bootstrap.sh" --profile "$BOOTSTRAP_PROFILE" "$TARGET_REPO"
  else
    print_section "Project Update"
    printf 'Target is a git repo but does not look like an installed Operator Kit project.\n'
    printf 'Missing: operator.config.env\n'
    printf 'To bootstrap intentionally, run:\n'
    printf '  bash %s/scripts/operator-sync.sh --target %s --bootstrap-if-missing\n' "$SOURCE_PATH" "$TARGET_REPO"
    printf 'For Cursor-first projects without Codex, run:\n'
    printf '  bash %s/scripts/operator-sync.sh --target %s --bootstrap-if-missing --bootstrap-profile cursor --skip-skills\n' "$SOURCE_PATH" "$TARGET_REPO"
    exit 0
  fi
fi

print_section "Project Update"
update_args=(--source "$SOURCE_PATH" --target "$TARGET_REPO" --no-fetch)
if grep -q -- '--channel' "$SOURCE_PATH/scripts/operator-update.sh" 2>/dev/null; then
  update_args+=(--channel "$CHANNEL")
fi
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
printf 'Restart or reopen Codex Desktop and reload Cursor so refreshed skills appear in host skill lists.\n'
