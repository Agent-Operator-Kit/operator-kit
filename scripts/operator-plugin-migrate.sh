#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-plugin-migrate.sh [options]

Migrates Codex Desktop from legacy Operator Kit skill directories in
~/.codex/skills to the V3 operator-kit Codex plugin.

The migration is plugin-first and reversible:
  1. prepare a local Codex marketplace for plugins/operator-kit
  2. install/reinstall operator-kit through `codex plugin add`
  3. move legacy Operator-owned skill directories into a timestamped backup
  4. leave unrelated custom skill directories in place

Options:
  --source <path>              Operator Kit source checkout. Defaults to this checkout.
  --codex-home <path>          Codex home directory. Defaults to $CODEX_HOME or ~/.codex.
  --marketplace-root <path>    Local marketplace root to create/update.
                               Defaults to <codex-home>/operator-kit-plugin-marketplace.
  --marketplace-name <name>    Marketplace name. Defaults to operator-kit-local.
  --codex-bin <path|name>      Codex CLI. Defaults to $CODEX_BIN or codex.
  --dry-run                    Show what would change without writing files.
  --skip-plugin-install        Prepare/inspect migration without calling Codex plugin commands.
  --skip-legacy-retire         Do not move legacy ~/.codex/skills directories.
  --preserve-changed-legacy    Leave changed legacy Operator skill directories in place.
  --restore <backup-dir>       Restore legacy skills from a previous backup and exit.
  -h, --help                   Show this help.

Examples:
  bash scripts/operator-plugin-migrate.sh --dry-run
  bash scripts/operator-plugin-migrate.sh
  bash scripts/operator-plugin-migrate.sh --restore ~/.codex/skills/.operator-kit-legacy-backups/20260608T190000Z
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE="${OPERATOR_KIT_SOURCE:-$DEFAULT_SOURCE}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
MARKETPLACE_ROOT=""
MARKETPLACE_NAME="${OPERATOR_PLUGIN_MARKETPLACE_NAME:-operator-kit-local}"
CODEX_BIN="${CODEX_BIN:-codex}"
DRY_RUN=0
SKIP_PLUGIN_INSTALL=0
SKIP_LEGACY_RETIRE=0
PRESERVE_CHANGED_LEGACY=0
RESTORE_BACKUP=""
SOURCE_PATH=""
SOURCE_REVISION="unknown"
BACKUP_DIR=""
MOVED_SKILLS=0
LEFT_CHANGED_SKILLS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --codex-home)
      CODEX_HOME_DIR="${2:-}"
      shift 2
      ;;
    --marketplace-root)
      MARKETPLACE_ROOT="${2:-}"
      shift 2
      ;;
    --marketplace-name)
      MARKETPLACE_NAME="${2:-}"
      shift 2
      ;;
    --codex-bin)
      CODEX_BIN="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-plugin-install)
      SKIP_PLUGIN_INSTALL=1
      shift
      ;;
    --skip-legacy-retire)
      SKIP_LEGACY_RETIRE=1
      shift
      ;;
    --preserve-changed-legacy)
      PRESERVE_CHANGED_LEGACY=1
      shift
      ;;
    --restore)
      RESTORE_BACKUP="${2:-}"
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

if [ -z "$SOURCE" ]; then
  printf 'Missing --source value.\n' >&2
  exit 1
fi

if [ -z "$CODEX_HOME_DIR" ]; then
  printf 'Missing --codex-home value.\n' >&2
  exit 1
fi

if [ -z "$MARKETPLACE_NAME" ]; then
  printf 'Missing --marketplace-name value.\n' >&2
  exit 1
fi

if [ -z "$MARKETPLACE_ROOT" ]; then
  MARKETPLACE_ROOT="$CODEX_HOME_DIR/operator-kit-plugin-marketplace"
fi

print_section() {
  printf '\n## %s\n' "$1"
}

run_or_print() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would run:'
    while [ "$#" -gt 0 ]; do
      printf ' %s' "$1"
      shift
    done
    printf '\n'
    return 0
  fi

  "$@"
}

restore_legacy_skills() {
  local entry
  local skill
  local dest
  local restored=0

  if [ -z "$RESTORE_BACKUP" ]; then
    printf 'Missing --restore backup directory.\n' >&2
    exit 1
  fi

  if [ ! -d "$RESTORE_BACKUP" ]; then
    printf 'Backup directory not found: %s\n' "$RESTORE_BACKUP" >&2
    exit 1
  fi

  print_section "Restore Legacy Codex Skills"
  printf 'Backup: %s\n' "$RESTORE_BACKUP"
  printf 'Codex home: %s\n' "$CODEX_HOME_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Mode: dry run\n'
  fi

  for entry in "$RESTORE_BACKUP"/*; do
    [ -d "$entry" ] || continue
    skill="$(basename "$entry")"
    dest="$CODEX_HOME_DIR/skills/$skill"

    if [ -e "$dest" ] || [ -L "$dest" ]; then
      printf 'Refusing to overwrite existing skill during restore: %s\n' "$dest" >&2
      exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'Would restore %s -> %s\n' "$entry" "$dest"
    else
      mkdir -p "$CODEX_HOME_DIR/skills"
      mv "$entry" "$dest"
      printf 'restored %s -> %s\n' "$entry" "$dest"
    fi
    restored=$((restored + 1))
  done

  printf 'Legacy skills restored: %s\n' "$restored"
  printf 'Restart or reopen Codex Desktop so the skill list refreshes.\n'
}

if [ -n "$RESTORE_BACKUP" ]; then
  restore_legacy_skills
  exit 0
fi

prepare_source() {
  if [ ! -d "$SOURCE" ]; then
    printf 'Operator Kit source must be a local checkout for plugin migration: %s\n' "$SOURCE" >&2
    exit 1
  fi

  SOURCE_PATH="$(cd "$SOURCE" && pwd)"

  if [ ! -d "$SOURCE_PATH/plugins/operator-kit" ]; then
    printf 'Missing plugin package: %s/plugins/operator-kit\n' "$SOURCE_PATH" >&2
    exit 1
  fi

  if [ ! -f "$SOURCE_PATH/plugins/operator-kit/.codex-plugin/plugin.json" ]; then
    printf 'Missing plugin manifest: %s/plugins/operator-kit/.codex-plugin/plugin.json\n' "$SOURCE_PATH" >&2
    exit 1
  fi

  if [ ! -d "$SOURCE_PATH/skills/codex" ]; then
    printf 'Missing canonical Codex skills: %s/skills/codex\n' "$SOURCE_PATH" >&2
    exit 1
  fi

  SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"
}

write_marketplace() {
  local marketplace_file="$MARKETPLACE_ROOT/.agents/plugins/marketplace.json"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would write marketplace: %s\n' "$marketplace_file"
    return 0
  fi

  mkdir -p "$MARKETPLACE_ROOT/.agents/plugins"
  python3 - "$marketplace_file" "$MARKETPLACE_NAME" <<'PY'
import json
import sys

path = sys.argv[1]
marketplace_name = sys.argv[2]
payload = {
    "name": marketplace_name,
    "interface": {
        "displayName": "Operator Kit Local"
    },
    "plugins": [
        {
            "name": "operator-kit",
            "source": {
                "source": "local",
                "path": "./plugins/operator-kit"
            },
            "policy": {
                "installation": "AVAILABLE",
                "authentication": "ON_INSTALL"
            },
            "category": "Developer Tools"
        }
    ]
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
  printf 'wrote marketplace: %s\n' "$marketplace_file"
}

copy_plugin_package() {
  local dest="$MARKETPLACE_ROOT/plugins/operator-kit"

  print_section "Plugin Marketplace"
  printf 'Source plugin: %s/plugins/operator-kit\n' "$SOURCE_PATH"
  printf 'Marketplace root: %s\n' "$MARKETPLACE_ROOT"
  printf 'Marketplace name: %s\n' "$MARKETPLACE_NAME"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would copy plugin package -> %s\n' "$dest"
    write_marketplace
    return 0
  fi

  mkdir -p "$MARKETPLACE_ROOT/plugins"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='.DS_Store' "$SOURCE_PATH/plugins/operator-kit/" "$dest/"
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    (cd "$SOURCE_PATH/plugins/operator-kit" && tar --exclude='.DS_Store' -cf - .) | (cd "$dest" && tar -xf -)
  fi
  printf 'copied plugin package -> %s\n' "$dest"
  write_marketplace
}

codex_marketplace_already_added() {
  "$CODEX_BIN" plugin marketplace list 2>/dev/null | grep -F "$MARKETPLACE_ROOT" >/dev/null 2>&1
}

install_plugin() {
  print_section "Codex Plugin Install"

  if [ "$SKIP_PLUGIN_INSTALL" -eq 1 ]; then
    printf 'Skipped.\n'
    return 0
  fi

  if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
    printf 'Codex CLI not found: %s\n' "$CODEX_BIN" >&2
    printf 'Install the plugin manually or rerun with --codex-bin <path>.\n' >&2
    exit 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    run_or_print "$CODEX_BIN" plugin marketplace add "$MARKETPLACE_ROOT"
    run_or_print "$CODEX_BIN" plugin add "operator-kit@$MARKETPLACE_NAME"
    return 0
  fi

  if codex_marketplace_already_added; then
    printf 'marketplace already configured: %s\n' "$MARKETPLACE_ROOT"
  else
    "$CODEX_BIN" plugin marketplace add "$MARKETPLACE_ROOT"
  fi

  "$CODEX_BIN" plugin add "operator-kit@$MARKETPLACE_NAME"
}

list_bundled_skills() {
  local dir
  find "$SOURCE_PATH/skills/codex" -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r dir; do
    [ -f "$dir/SKILL.md" ] || continue
    basename "$dir"
  done
}

ensure_backup_dir() {
  local base_dir
  local suffix=1

  if [ -n "$BACKUP_DIR" ]; then
    return 0
  fi

  base_dir="$CODEX_HOME_DIR/skills/.operator-kit-legacy-backups/$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="$base_dir"
  while [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; do
    BACKUP_DIR="$base_dir-$suffix"
    suffix=$((suffix + 1))
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
Operator Kit legacy Codex skill backup
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Source: $SOURCE_PATH
Source revision: $SOURCE_REVISION
Marketplace root: $MARKETPLACE_ROOT
Marketplace name: $MARKETPLACE_NAME
EOF
}

skill_matches_source() {
  local skill="$1"
  local dest="$2"
  local src="$SOURCE_PATH/skills/codex/$skill"

  [ -d "$src" ] || return 1
  diff -qr -x .DS_Store "$src" "$dest" >/dev/null 2>&1
}

retire_skill() {
  local skill="$1"
  local dest="$CODEX_HOME_DIR/skills/$skill"
  local reason=""

  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    return 0
  fi

  if skill_matches_source "$skill" "$dest"; then
    reason="exact copy"
  elif [ "$PRESERVE_CHANGED_LEGACY" -eq 1 ]; then
    printf 'left changed legacy skill in place: %s\n' "$dest"
    LEFT_CHANGED_SKILLS=$((LEFT_CHANGED_SKILLS + 1))
    return 0
  else
    reason="changed legacy copy"
  fi

  ensure_backup_dir

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would retire legacy skill (%s): %s -> %s/%s\n' "$reason" "$dest" "$BACKUP_DIR" "$skill"
  else
    if [ -e "$BACKUP_DIR/$skill" ] || [ -L "$BACKUP_DIR/$skill" ]; then
      printf 'Backup destination already exists: %s/%s\n' "$BACKUP_DIR" "$skill" >&2
      exit 1
    fi
    mv "$dest" "$BACKUP_DIR/$skill"
    printf 'retired legacy skill (%s): %s -> %s/%s\n' "$reason" "$dest" "$BACKUP_DIR" "$skill"
  fi

  MOVED_SKILLS=$((MOVED_SKILLS + 1))
}

retire_legacy_skills() {
  local skill

  print_section "Legacy Codex Skills"

  if [ "$SKIP_LEGACY_RETIRE" -eq 1 ]; then
    printf 'Skipped.\n'
    return 0
  fi

  if [ "$SKIP_PLUGIN_INSTALL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    printf 'Refusing to retire legacy skills when plugin install was skipped.\n' >&2
    printf 'Rerun without --skip-plugin-install or add --dry-run for inspection.\n' >&2
    exit 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Mode: dry run\n'
  fi

  while IFS= read -r skill; do
    retire_skill "$skill"
  done < <(list_bundled_skills)

  printf 'Legacy skills retired: %s\n' "$MOVED_SKILLS"
  if [ "$MOVED_SKILLS" -gt 0 ]; then
    printf 'Backup: %s\n' "$BACKUP_DIR"
  fi
  if [ "$LEFT_CHANGED_SKILLS" -gt 0 ]; then
    printf 'Changed legacy skills left in place: %s\n' "$LEFT_CHANGED_SKILLS"
    printf 'Rerun without --preserve-changed-legacy when they should yield to the plugin.\n'
  fi
}

prepare_source

print_section "Operator Kit Plugin Migration"
printf 'Source: %s\n' "$SOURCE_PATH"
printf 'Source revision: %s\n' "$SOURCE_REVISION"
printf 'Codex home: %s\n' "$CODEX_HOME_DIR"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Mode: dry run\n'
fi

copy_plugin_package
install_plugin
retire_legacy_skills

print_section "Done"
printf 'Restart or reopen Codex Desktop so plugin skills are loaded and retired legacy skills disappear from the skill list.\n'
