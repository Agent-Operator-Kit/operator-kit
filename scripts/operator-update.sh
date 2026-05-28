#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>] [--dry-run] [--no-fetch]

Updates an installed Agent Operator Kit project from the latest kit source.

By default, project-specific files are preserved:
  operator.config.env
  AGENTS.md
  CODEX.md
  CLAUDE.md
  .claude/*
  .cursor/*

Evergreen scripts are refreshed from the kit source.
USAGE
}

SOURCE="${OPERATOR_KIT_SOURCE:-https://github.com/Agent-Operator-Kit/operator-kit.git}"
TARGET_REPO=""
DRY_RUN=0
NO_FETCH=0
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

if [ -z "$TARGET_REPO" ]; then
  TARGET_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ -z "$TARGET_REPO" ] || ! git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf 'Target is not a git repository: %s\n' "${TARGET_REPO:-<unset>}" >&2
  exit 1
fi

TARGET_REPO="$(git -C "$TARGET_REPO" rev-parse --show-toplevel)"

if [ ! -f "$TARGET_REPO/operator.config.env" ]; then
  printf 'Target does not look like an installed Operator Kit project: %s\n' "$TARGET_REPO" >&2
  printf 'Missing: operator.config.env\n' >&2
  exit 1
fi

prepare_source() {
  if [ -d "$SOURCE" ] && [ -f "$SOURCE/scripts/operator-bootstrap.sh" ]; then
    SOURCE_PATH="$(cd "$SOURCE" && pwd)"
    if [ "$NO_FETCH" -eq 0 ] && git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git -C "$SOURCE_PATH" status --porcelain)" ]; then
        printf 'Source has local changes; skipping git pull: %s\n' "$SOURCE_PATH" >&2
      else
        git -C "$SOURCE_PATH" pull --ff-only >/dev/null
      fi
    fi
  else
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-update.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
  fi

  if [ ! -f "$SOURCE_PATH/scripts/operator-bootstrap.sh" ]; then
    printf 'Invalid Operator Kit source: %s\n' "$SOURCE_PATH" >&2
    exit 1
  fi
}

prepare_source

SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

REPORT_DIR="$(mktemp -d /tmp/operator-kit-update-report.XXXXXX)"
trap 'rm -rf "$REPORT_DIR"; cleanup' EXIT
touch "$REPORT_DIR/updated" "$REPORT_DIR/installed" "$REPORT_DIR/preserved" "$REPORT_DIR/unchanged" "$REPORT_DIR/planned"

record() {
  printf '%s\n' "$2" >> "$REPORT_DIR/$1"
}

copy_refresh() {
  local src="$1"
  local dest="$2"
  local label="$3"
  local existed=0

  if [ ! -f "$src" ]; then
    printf 'Missing source file: %s\n' "$src" >&2
    exit 1
  fi

  if [ -f "$dest" ]; then
    existed=1
  fi

  if [ "$existed" -eq 1 ] && cmp -s "$src" "$dest"; then
    record unchanged "$label"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record planned "$label"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod +x "$dest"
  if [ "$existed" -eq 1 ]; then
    record updated "$label"
  else
    record installed "$label"
  fi
}

install_missing() {
  local src="$1"
  local dest="$2"
  local label="$3"

  if [ -f "$dest" ]; then
    record preserved "$label"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record planned "$label"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  record installed "$label"
}

append_gitignore_snippet() {
  local snippet="$SOURCE_PATH/templates/repo/gitignore.snippet"
  local gitignore="$TARGET_REPO/.gitignore"
  if grep -q 'Agent Operator Kit generated state' "$gitignore" 2>/dev/null; then
    record unchanged ".gitignore operator snippet"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record planned ".gitignore operator snippet"
    return 0
  fi

  {
    printf '\n'
    cat "$snippet"
  } >> "$gitignore"
  record updated ".gitignore operator snippet"
}

# shellcheck source=/dev/null
source "$TARGET_REPO/operator.config.env"
: "${OPERATOR_DIR:?OPERATOR_DIR is required in operator.config.env}"

mkdir -p "$TARGET_REPO/scripts"
for script in operator-lib.sh operator-tmux.sh operator-status.sh operator-task.sh operator-dispatch.sh operator-collect.sh operator-summary.sh operator-memory.sh operator-roadmap.sh operator-feedback.sh operator-update.sh operator-sync.sh operator-upgrade.sh; do
  copy_refresh "$SOURCE_PATH/scripts/$script" "$TARGET_REPO/scripts/$script" "scripts/$script"
done

install_missing "$SOURCE_PATH/templates/repo/AGENTS.md" "$TARGET_REPO/AGENTS.md" "AGENTS.md"
install_missing "$SOURCE_PATH/templates/repo/CODEX.md" "$TARGET_REPO/CODEX.md" "CODEX.md"
install_missing "$SOURCE_PATH/templates/repo/CLAUDE.md" "$TARGET_REPO/CLAUDE.md" "CLAUDE.md"
install_missing "$SOURCE_PATH/templates/claude/commands/operator-bootstrap.md" "$TARGET_REPO/.claude/commands/operator-bootstrap.md" ".claude/commands/operator-bootstrap.md"
install_missing "$SOURCE_PATH/templates/claude/commands/operator-status.md" "$TARGET_REPO/.claude/commands/operator-status.md" ".claude/commands/operator-status.md"
install_missing "$SOURCE_PATH/templates/claude/agents/operator-workflow.md" "$TARGET_REPO/.claude/agents/operator-workflow.md" ".claude/agents/operator-workflow.md"
install_missing "$SOURCE_PATH/templates/cursor/rules/operator-workflow.mdc" "$TARGET_REPO/.cursor/rules/operator-workflow.mdc" ".cursor/rules/operator-workflow.mdc"
for cursor_skill in operator-workflow operator operator-planner operator-feedback design-agent incubation; do
  install_missing "$SOURCE_PATH/templates/cursor/skills/$cursor_skill/SKILL.md" "$TARGET_REPO/.cursor/skills/$cursor_skill/SKILL.md" ".cursor/skills/$cursor_skill/SKILL.md"
done
if [ ! -f "$TARGET_REPO/.cursor/environment.json" ]; then
  install_missing "$SOURCE_PATH/templates/cursor/environment.json.example" "$TARGET_REPO/.cursor/environment.json.example" ".cursor/environment.json.example"
fi

mkdir -p "$OPERATOR_DIR/tasks" "$OPERATOR_DIR/captures" "$OPERATOR_DIR/memory" "$OPERATOR_DIR/roadmap/items" "$OPERATOR_DIR/roadmap/inbox" "$OPERATOR_DIR/roadmap/views"
if [ "$DRY_RUN" -eq 0 ]; then
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-memory.sh" init >/dev/null
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-roadmap.sh" init >/dev/null
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-feedback.sh" init >/dev/null
fi
install_missing "$SOURCE_PATH/templates/operator-workspace/README.md" "$OPERATOR_DIR/README.md" "OPERATOR_DIR/README.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/README.md" "$OPERATOR_DIR/roadmap/README.md" "OPERATOR_DIR/roadmap/README.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/items/_template.md" "$OPERATOR_DIR/roadmap/items/_template.md" "OPERATOR_DIR/roadmap/items/_template.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/inbox/_feedback-template.md" "$OPERATOR_DIR/roadmap/inbox/_feedback-template.md" "OPERATOR_DIR/roadmap/inbox/_feedback-template.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/views/ready.md" "$OPERATOR_DIR/roadmap/views/ready.md" "OPERATOR_DIR/roadmap/views/ready.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/views/blocked.md" "$OPERATOR_DIR/roadmap/views/blocked.md" "OPERATOR_DIR/roadmap/views/blocked.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/views/now-next-later.md" "$OPERATOR_DIR/roadmap/views/now-next-later.md" "OPERATOR_DIR/roadmap/views/now-next-later.md"
install_missing "$SOURCE_PATH/templates/operator-workspace/roadmap/views/shipped.md" "$OPERATOR_DIR/roadmap/views/shipped.md" "OPERATOR_DIR/roadmap/views/shipped.md"
append_gitignore_snippet

print_section() {
  printf '\n## %s\n' "$1"
}

print_list() {
  local file="$1"
  if [ -s "$file" ]; then
    sed 's/^/  - /' "$file"
  else
    printf '  - none\n'
  fi
}

print_section "Agent Operator Kit Update"
printf 'Target: %s\n' "$TARGET_REPO"
printf 'Source: %s\n' "$SOURCE_PATH"
printf 'Source revision: %s\n' "$SOURCE_REVISION"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Mode: dry run\n'
fi

print_section "Updated"
print_list "$REPORT_DIR/updated"

print_section "Installed Missing"
print_list "$REPORT_DIR/installed"

print_section "Preserved Project-Specific"
print_list "$REPORT_DIR/preserved"

print_section "Unchanged"
print_list "$REPORT_DIR/unchanged"

if [ "$DRY_RUN" -eq 1 ]; then
  print_section "Would Change"
  print_list "$REPORT_DIR/planned"
fi

print_section "Next Checks"
printf '  - bash -n scripts/*.sh\n'
printf '  - bash scripts/operator-status.sh\n'
printf '  - bash scripts/operator-summary.sh\n'
printf '  - bash scripts/operator-memory.sh status\n'
printf '  - bash scripts/operator-roadmap.sh status\n'
printf '  - git status --short\n'
