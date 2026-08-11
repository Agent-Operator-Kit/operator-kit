#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>] [--channel stable|v2.1|v3|latest] [--dry-run] [--no-fetch]

Updates an installed Agent Operator Kit project from an Operator Kit source.

By default, project-specific files are preserved:
  operator.config.env
  AGENTS.md
  CODEX.md
  CLAUDE.md
  .claude/*
  .cursor/*

Evergreen scripts are refreshed from the kit source.

Channels:
  stable/v2.1  Current pinned release.
  v3           Plugin-based adapter release, once the v3 tag is published.
  latest       Current source, including V5 control-plane tooling. Existing
               V4 projects remain V4 until explicit operator-v5-migrate apply.
USAGE
}

SOURCE="${OPERATOR_KIT_SOURCE:-https://github.com/Agent-Operator-Kit/operator-kit.git}"
CHANNEL="${OPERATOR_KIT_CHANNEL:-stable}"
SOURCE_REF=""
TARGET_REPO=""
DRY_RUN=0
NO_FETCH=0
TMP_ROOT=""
OBSOLETE_CURSOR_SKILLS=(product-manager)

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
    --channel)
      CHANNEL="${2:-}"
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

  if [ -d "$SOURCE" ] && [ -f "$SOURCE/scripts/operator-bootstrap.sh" ]; then
    SOURCE_PATH="$(cd "$SOURCE" && pwd)"
    if [ "$DRY_RUN" -eq 0 ] && [ "$NO_FETCH" -eq 0 ] && git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
      TMP_ROOT="$(mktemp -d /tmp/operator-kit-update.XXXXXX)"
      mkdir -p "$TMP_ROOT/operator-kit"
      git -C "$SOURCE_PATH" archive "$SOURCE_REF" | tar -x -C "$TMP_ROOT/operator-kit"
      SOURCE_PATH="$TMP_ROOT/operator-kit"
    fi
  else
    TMP_ROOT="$(mktemp -d /tmp/operator-kit-update.XXXXXX)"
    git clone --depth 1 "$SOURCE" "$TMP_ROOT/operator-kit" >/dev/null
    SOURCE_PATH="$TMP_ROOT/operator-kit"
    if [ -n "$SOURCE_REF" ]; then
      git -C "$SOURCE_PATH" fetch --depth 1 origin "refs/tags/$SOURCE_REF:refs/tags/$SOURCE_REF" >/dev/null 2>&1 || true
      git -C "$SOURCE_PATH" checkout "$SOURCE_REF" >/dev/null
    fi
  fi

  if [ ! -f "$SOURCE_PATH/scripts/operator-bootstrap.sh" ]; then
    printf 'Invalid Operator Kit source: %s\n' "$SOURCE_PATH" >&2
    exit 1
  fi
}

prepare_source

# shellcheck source=/dev/null
source "$SOURCE_PATH/scripts/operator-lib.sh"

SOURCE_REVISION="$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || printf unknown)"

REPORT_DIR="$(mktemp -d /tmp/operator-kit-update-report.XXXXXX)"
trap 'rm -rf "$REPORT_DIR"; cleanup' EXIT
touch "$REPORT_DIR/updated" "$REPORT_DIR/installed" "$REPORT_DIR/preserved" "$REPORT_DIR/unchanged" "$REPORT_DIR/removed" "$REPORT_DIR/planned"

record() {
  printf '%s\n' "$2" >> "$REPORT_DIR/$1"
}

copy_refresh_with_mode() {
  local src="$1"
  local dest="$2"
  local label="$3"
  local mode="$4"
  local existed=0

  if [ ! -f "$src" ]; then
    printf 'Missing source file: %s\n' "$src" >&2
    exit 1
  fi

  if [ -f "$dest" ]; then
    existed=1
  fi

  if [ "$existed" -eq 1 ] && cmp -s "$src" "$dest"; then
    local current_mode
    current_mode="$(stat -f '%Lp' "$dest" 2>/dev/null || stat -c '%a' "$dest" 2>/dev/null || printf unknown)"
    if [ "$current_mode" = "${mode#0}" ]; then
      record unchanged "$label"
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      record planned "$label (mode $current_mode -> ${mode#0})"
      return 0
    fi
    chmod "$mode" "$dest"
    record updated "$label (corrected mode)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record planned "$label"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  if [ "$existed" -eq 1 ]; then
    record updated "$label"
  else
    record installed "$label"
  fi
}

copy_refresh_executable() {
  copy_refresh_with_mode "$1" "$2" "$3" 0755
}

copy_refresh_plain() {
  copy_refresh_with_mode "$1" "$2" "$3" 0644
}

copy_refresh_plain_directory() {
  local src_dir="$1"
  local dest_dir="$2"
  local label_prefix="$3"
  local src
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$dest_dir"
    chmod 0755 "$dest_dir"
  fi
  for src in "$src_dir"/*; do
    [ -f "$src" ] || continue
    copy_refresh_plain "$src" "$dest_dir/$(basename "$src")" "$label_prefix/$(basename "$src")"
  done
}

remove_obsolete_path() {
  local path="$1"
  local label="$2"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record planned "remove obsolete $label"
    return 0
  fi

  rm -rf "$path"
  record removed "$label"
}

remove_obsolete_project_assets() {
  local skill

  for skill in "${OBSOLETE_CURSOR_SKILLS[@]}"; do
    remove_obsolete_path "$TARGET_REPO/.cursor/skills/$skill" ".cursor/skills/$skill"
    remove_obsolete_path "$TARGET_REPO/.cursor/rules/$skill.mdc" ".cursor/rules/$skill.mdc"
    remove_obsolete_path "$TARGET_REPO/.claude/agents/$skill.md" ".claude/agents/$skill.md"
    remove_obsolete_path "$TARGET_REPO/.claude/commands/$skill.md" ".claude/commands/$skill.md"
  done
}

install_missing_plain() {
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
  chmod 0644 "$dest"
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

V5_EXTERNAL_STATE_ALLOWED=1

remove_obsolete_project_assets

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET_REPO/scripts"
fi
for script in operator-lib.sh operator-tmux.sh operator-status.sh operator-task.sh operator-dispatch.sh operator-collect.sh operator-summary.sh operator-memory.sh operator-roadmap.sh operator-feedback.sh operator-feature.sh operator-conflicts.sh operator-catalog.sh operator-system-map.sh operator-recommend-lanes.sh operator-plan-batch.sh operator-role-map.sh operator-graph.sh operator-scheduler.sh operator-loop.sh operator-host.sh operator-proof-broker.sh operator-design-flow.sh operator-v5-migrate.sh operator-v5-provision.sh codex-skills-install.sh cursor-skills-install.sh operator-update.sh operator-sync.sh operator-upgrade.sh; do
  if [ ! -f "$SOURCE_PATH/scripts/$script" ]; then
    record unchanged "scripts/$script unavailable in selected channel"
    continue
  fi
  copy_refresh_executable "$SOURCE_PATH/scripts/$script" "$TARGET_REPO/scripts/$script" "scripts/$script"
done

for helper in operator_graph.py operator_host.py operator_design_provider.py operator_v5_migrate.py operator_v5_provision.py; do
  if [ ! -f "$SOURCE_PATH/scripts/$helper" ]; then
    record unchanged "scripts/$helper unavailable in selected channel"
    continue
  fi
  copy_refresh_plain "$SOURCE_PATH/scripts/$helper" "$TARGET_REPO/scripts/$helper" "scripts/$helper"
done

if [ -d "$SOURCE_PATH/schemas/operator-v5" ]; then
  copy_refresh_plain_directory "$SOURCE_PATH/schemas/operator-v5" "$TARGET_REPO/schemas/operator-v5" "schemas/operator-v5"
fi

install_missing_plain "$SOURCE_PATH/templates/repo/AGENTS.md" "$TARGET_REPO/AGENTS.md" "AGENTS.md"
install_missing_plain "$SOURCE_PATH/templates/repo/CODEX.md" "$TARGET_REPO/CODEX.md" "CODEX.md"
install_missing_plain "$SOURCE_PATH/templates/repo/CLAUDE.md" "$TARGET_REPO/CLAUDE.md" "CLAUDE.md"
for command_template in operator-bootstrap.md operator-status.md operator-open.md operator-tick.md operator-goal-context.md; do
  if [ -f "$SOURCE_PATH/templates/claude/commands/$command_template" ]; then
    install_missing_plain "$SOURCE_PATH/templates/claude/commands/$command_template" "$TARGET_REPO/.claude/commands/$command_template" ".claude/commands/$command_template"
  fi
done
install_missing_plain "$SOURCE_PATH/templates/claude/agents/operator-workflow.md" "$TARGET_REPO/.claude/agents/operator-workflow.md" ".claude/agents/operator-workflow.md"
install_missing_plain "$SOURCE_PATH/templates/cursor/rules/operator-workflow.mdc" "$TARGET_REPO/.cursor/rules/operator-workflow.mdc" ".cursor/rules/operator-workflow.mdc"
for cursor_skill in operator-workflow operator operator-planner operator-feedback design-agent incubation ux-auditor user-journey; do
  install_missing_plain "$SOURCE_PATH/templates/cursor/skills/$cursor_skill/SKILL.md" "$TARGET_REPO/.cursor/skills/$cursor_skill/SKILL.md" ".cursor/skills/$cursor_skill/SKILL.md"
done
if [ ! -f "$TARGET_REPO/.cursor/environment.json" ]; then
  install_missing_plain "$SOURCE_PATH/templates/cursor/environment.json.example" "$TARGET_REPO/.cursor/environment.json.example" ".cursor/environment.json.example"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$OPERATOR_DIR/tasks" "$OPERATOR_DIR/captures" "$OPERATOR_DIR/memory" "$OPERATOR_DIR/features" "$OPERATOR_DIR/roadmap/items" "$OPERATOR_DIR/roadmap/inbox" "$OPERATOR_DIR/roadmap/views" "$OPERATOR_DIR/catalog/roles" "$OPERATOR_DIR/catalog/patterns"
fi
target_real="$(cd "$TARGET_REPO" && pwd -P)"
operator_real="$(cd "$OPERATOR_DIR" 2>/dev/null && pwd -P || true)"
case "$operator_real" in
  "$target_real"|"$target_real"/*)
    V5_EXTERNAL_STATE_ALLOWED=0
    record unchanged 'V5 relocation/migration blocked: OPERATOR_DIR is repo-local; relocate it outside the repository before creating V5 runtime state'
    ;;
  "")
    V5_EXTERNAL_STATE_ALLOWED=0
    record unchanged 'V5 relocation/migration blocked: OPERATOR_DIR could not be validated as an external directory'
    ;;
esac
if [ "$DRY_RUN" -eq 0 ]; then
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-memory.sh" init >/dev/null
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-roadmap.sh" init >/dev/null
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-feedback.sh" init >/dev/null
  if [ -f "$TARGET_REPO/scripts/operator-feature.sh" ]; then
    OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-feature.sh" init >/dev/null
  fi
fi
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/README.md" "$OPERATOR_DIR/README.md" "OPERATOR_DIR/README.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/catalog/README.md" "$OPERATOR_DIR/catalog/README.md" "OPERATOR_DIR/catalog/README.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/catalog/roles/_template.md" "$OPERATOR_DIR/catalog/roles/_template.md" "OPERATOR_DIR/catalog/roles/_template.md"
for role_template in api-contracts auth-permissions data-storage deployment-recovery design-system evals-testing high-risk-operations knowledge-base llm-runtime mobile-app mobile-release observability provider-integration web-ui; do
  install_missing_plain "$SOURCE_PATH/templates/operator-workspace/catalog/roles/$role_template.md" "$OPERATOR_DIR/catalog/roles/$role_template.md" "OPERATOR_DIR/catalog/roles/$role_template.md"
done
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/catalog/patterns/_template.md" "$OPERATOR_DIR/catalog/patterns/_template.md" "OPERATOR_DIR/catalog/patterns/_template.md"
for pattern_template in api-contracts architecture-pattern-library llm-runtime mobile-release observability provider-integration; do
  install_missing_plain "$SOURCE_PATH/templates/operator-workspace/catalog/patterns/$pattern_template.md" "$OPERATOR_DIR/catalog/patterns/$pattern_template.md" "OPERATOR_DIR/catalog/patterns/$pattern_template.md"
done
if [ "$DRY_RUN" -eq 0 ]; then
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-catalog.sh" init >/dev/null
  if [ -f "$TARGET_REPO/scripts/operator-role-map.sh" ]; then
    OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-role-map.sh" init >/dev/null
  fi
  OPERATOR_CONFIG="$TARGET_REPO/operator.config.env" bash "$TARGET_REPO/scripts/operator-system-map.sh" refresh >/dev/null
fi
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/README.md" "$OPERATOR_DIR/roadmap/README.md" "OPERATOR_DIR/roadmap/README.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/items/_template.md" "$OPERATOR_DIR/roadmap/items/_template.md" "OPERATOR_DIR/roadmap/items/_template.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/inbox/_feedback-template.md" "$OPERATOR_DIR/roadmap/inbox/_feedback-template.md" "OPERATOR_DIR/roadmap/inbox/_feedback-template.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/views/ready.md" "$OPERATOR_DIR/roadmap/views/ready.md" "OPERATOR_DIR/roadmap/views/ready.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/views/blocked.md" "$OPERATOR_DIR/roadmap/views/blocked.md" "OPERATOR_DIR/roadmap/views/blocked.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/views/now-next-later.md" "$OPERATOR_DIR/roadmap/views/now-next-later.md" "OPERATOR_DIR/roadmap/views/now-next-later.md"
install_missing_plain "$SOURCE_PATH/templates/operator-workspace/roadmap/views/shipped.md" "$OPERATOR_DIR/roadmap/views/shipped.md" "OPERATOR_DIR/roadmap/views/shipped.md"

if [ -f "$SOURCE_PATH/templates/operator-workspace/graph/README.md" ] && [ "$V5_EXTERNAL_STATE_ALLOWED" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    for runtime_dir in authority graph graph/bindings host loop migrations; do
      mkdir -p "$OPERATOR_DIR/$runtime_dir"
      chmod 0700 "$OPERATOR_DIR/$runtime_dir"
    done
  fi
  install_missing_plain "$SOURCE_PATH/templates/operator-workspace/graph/README.md" "$OPERATOR_DIR/graph/README.md" "OPERATOR_DIR/graph/README.md"
  prompt_result="$(operator_restore_design_prompt "$OPERATOR_DIR" "$SOURCE_PATH/templates/prompts/design-proposal.md" "$DRY_RUN")"
  record "$prompt_result" "OPERATOR_DIR/prompts/design-proposal.md"
fi
append_gitignore_snippet

case "${OPERATOR_KIT_VERSION:-2}" in
  4)
    record unchanged 'operator.config.env kit marker preserved at 4 (migration required)'
    ;;
  5)
    record unchanged 'operator.config.env kit marker already 5'
    ;;
  *)
    record unchanged "operator.config.env legacy kit marker preserved at ${OPERATOR_KIT_VERSION:-2}"
    ;;
esac

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
printf 'Channel: %s\n' "$CHANNEL"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Mode: dry run\n'
fi

print_section "Updated"
print_list "$REPORT_DIR/updated"

print_section "Installed Missing"
print_list "$REPORT_DIR/installed"

print_section "Preserved Project-Specific"
print_list "$REPORT_DIR/preserved"

print_section "Removed Obsolete"
print_list "$REPORT_DIR/removed"

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
printf '  - bash scripts/operator-feature.sh open --tool codex\n'
printf '  - bash scripts/operator-feature.sh active\n'
printf '  - bash scripts/operator-conflicts.sh summary\n'
printf '  - bash scripts/operator-catalog.sh list roles\n'
printf '  - bash scripts/operator-recommend-lanes.sh\n'
printf '  - bash scripts/operator-plan-batch.sh\n'
printf '  - bash scripts/operator-role-map.sh validate\n'
if [ "${OPERATOR_KIT_VERSION:-2}" = "4" ]; then
  if [ "$V5_EXTERNAL_STATE_ALLOWED" -eq 1 ]; then
    printf '  - migration required: review docs/guides/operator-v5-migration.md and run scripts/operator-v5-migrate.sh plan\n'
  else
    printf '  - relocation/migration blocked: move OPERATOR_DIR outside the repository, then rerun update and review migration\n'
  fi
fi
printf '  - git status --short\n'
