#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/cursor-skills-install.sh [options]

Installs or refreshes Operator Kit Cursor skills into ~/.cursor/skills.

Options:
  --latest              Pull the latest kit source before installing when source is a git repo.
  --source <path|url>   Operator Kit source path or git URL. Defaults to this checkout.
  --cursor-home <path>  Cursor home directory. Defaults to $CURSOR_HOME or ~/.cursor.
  --skill <name>        Install one skill. Can be repeated. Defaults to all bundled skills.
  --list                List installable skills and exit.
  --dry-run             Show what would be installed without writing files.
  --no-fetch            Do not pull or clone updates.
  -h, --help            Show this help.

Examples:
  bash scripts/cursor-skills-install.sh
  bash scripts/cursor-skills-install.sh --latest
  bash scripts/cursor-skills-install.sh --skill operator --skill design-agent
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${OPERATOR_KIT_SOURCE:-$DEFAULT_SOURCE}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"
LATEST=0
NO_FETCH=0
DRY_RUN=0
LIST_ONLY=0
TMP_ROOT=""
REQUESTED_SKILLS=()
OBSOLETE_SKILLS=(product-manager)

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest)
      LATEST=1
      shift
      ;;
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --cursor-home)
      CURSOR_HOME_DIR="${2:-}"
      shift 2
      ;;
    --skill)
      REQUESTED_SKILLS+=("${2:-}")
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-fetch)
      NO_FETCH=1
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

if [ -z "$SOURCE" ]; then
  printf 'Missing --source value.\n' >&2
  exit 1
fi

if [ -z "$CURSOR_HOME_DIR" ]; then
  printf 'Missing --cursor-home value.\n' >&2
  exit 1
fi

prepare_source() {
  if [ -d "$SOURCE" ]; then
    SOURCE_PATH="$(cd "$SOURCE" && pwd)"
    if [ "$LATEST" -eq 1 ] && [ "$NO_FETCH" -eq 0 ] && git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-cursor-skills.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
  fi

  if [ ! -d "$SOURCE_PATH/skills/cursor" ]; then
    printf 'Invalid Operator Kit source, missing skills/cursor: %s\n' "$SOURCE_PATH" >&2
    exit 1
  fi
}

skill_exists() {
  local skill="$1"
  [ -f "$SOURCE_PATH/skills/cursor/$skill/SKILL.md" ]
}

list_skills() {
  local dir
  find "$SOURCE_PATH/skills/cursor" -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r dir; do
    if [ -f "$dir/SKILL.md" ]; then
      basename "$dir"
    fi
  done
}

remove_obsolete_skills() {
  local skill
  local dest

  for skill in "${OBSOLETE_SKILLS[@]}"; do
    dest="$CURSOR_HOME_DIR/skills/$skill"
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'Would remove obsolete Cursor skill %s -> %s\n' "$skill" "$dest"
      continue
    fi

    rm -rf "$dest"
    printf 'removed obsolete Cursor skill %s -> %s\n' "$skill" "$dest"
  done
}

install_skill() {
  local skill="$1"
  local src="$SOURCE_PATH/skills/cursor/$skill"
  local dest="$CURSOR_HOME_DIR/skills/$skill"
  local action="install"

  if ! skill_exists "$skill"; then
    printf 'No bundled Cursor skill named %s in %s\n' "$skill" "$SOURCE_PATH/skills/cursor" >&2
    exit 1
  fi

  if [ -d "$dest" ]; then
    action="update"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would %s %s -> %s\n' "$action" "$skill" "$dest"
    return 0
  fi

  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='.DS_Store' "$src/" "$dest/"
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    (cd "$src" && tar --exclude='.DS_Store' -cf - .) | (cd "$dest" && tar -xf -)
  fi
  printf '%s %s -> %s\n' "$action" "$skill" "$dest"
}

prepare_source

SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

if [ "$LIST_ONLY" -eq 1 ]; then
  list_skills
  exit 0
fi

if [ "${#REQUESTED_SKILLS[@]}" -eq 0 ]; then
  while IFS= read -r skill; do
    REQUESTED_SKILLS+=("$skill")
  done < <(list_skills)
fi

if [ "${#REQUESTED_SKILLS[@]}" -eq 0 ]; then
  printf 'No installable Cursor skills found in: %s\n' "$SOURCE_PATH/skills/cursor" >&2
  exit 1
fi

printf 'Operator Kit Cursor skills\n'
printf 'Source: %s\n' "$SOURCE_PATH"
printf 'Source revision: %s\n' "$SOURCE_REVISION"
printf 'Cursor home: %s\n' "$CURSOR_HOME_DIR"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Mode: dry run\n'
fi
printf '\n'

remove_obsolete_skills

for skill in "${REQUESTED_SKILLS[@]}"; do
  install_skill "$skill"
done

printf '\nRestart or reload Cursor so the skill list refreshes.\n'
