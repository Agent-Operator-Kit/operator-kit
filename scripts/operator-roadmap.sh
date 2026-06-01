#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

ROADMAP_DIR="$OPERATOR_DIR/roadmap"
ITEMS_DIR="$ROADMAP_DIR/items"
INBOX_DIR="$ROADMAP_DIR/inbox"
VIEWS_DIR="$ROADMAP_DIR/views"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-roadmap.sh <command> [args]

Commands:
  init
      Create the local operator roadmap workspace.
  add "<title>" [--id RM-0001] [--type feature] [--status candidate]
      [--priority P2] [--impact medium] [--effort medium]
      [--confidence medium] [--areas mobile,backend] [--source-feedback FB-0001]
      [--depends-on RM-0001] [--required-roles provider-integration]
      [--owner-lane backend] [--contracts api,db]
      [--parallel-safe yes] [--approval-gate none]
      Add a roadmap/backlog item under OPERATOR_DIR/roadmap/items.
  list [--status ready] [--type bug]
      List roadmap items.
  status
      Show counts by status and type.
  ready
      List items ready for operator task dispatch.
  link-task <roadmap-id> <task-slug>
      Append an operator task link to a roadmap item.
  pr-note <roadmap-id> [--feedback FB-0001,FB-0002] [--task task-slug]
      [--why "..."] [--validation "..."]
      Print a PR/commit trace note.
USAGE
}

roadmap_init() {
  mkdir -p "$ITEMS_DIR" "$INBOX_DIR" "$VIEWS_DIR"

  if [ ! -f "$ROADMAP_DIR/README.md" ]; then
    {
      printf '# Operator Roadmap\n\n'
      printf 'Local roadmap, backlog, prioritization, and feedback planning live here.\n\n'
      printf 'This workspace is outside the app repo by design. Keep raw feedback,\n'
      printf 'triage notes, local priority views, and dispatch planning here. Link code\n'
      printf 'changes back with lightweight IDs in PRs or commits.\n\n'
      printf '## Layout\n\n'
      printf '%s\n' '- `items/`: roadmap and backlog items (`RM-*`).'
      printf '%s\n' '- `inbox/`: raw or triaged feedback items (`FB-*`).'
      printf '%s\n' '- `views/`: generated or curated planning views.'
    } > "$ROADMAP_DIR/README.md"
  fi

  for view in ready blocked now-next-later shipped; do
    if [ ! -f "$VIEWS_DIR/$view.md" ]; then
      {
        printf '# %s\n\n' "$view"
        printf 'Generated or curated local roadmap view.\n'
      } > "$VIEWS_DIR/$view.md"
    fi
  done
}

slugify() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c 1-64
}

next_id() {
  local prefix="$1"
  local dir="$2"
  local max="0"
  local file base num

  mkdir -p "$dir"
  while IFS= read -r file; do
    base="$(basename "$file")"
    num="$(printf '%s\n' "$base" | sed -nE "s/^${prefix}-([0-9]{4}).*/\1/p")"
    if [ -n "$num" ] && [ "$((10#$num))" -gt "$max" ]; then
      max="$((10#$num))"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-*.md" 2>/dev/null | sort)

  printf '%s-%04d\n' "$prefix" "$((max + 1))"
}

item_file_for_id() {
  local id="$1"
  local file
  file="$(find "$ITEMS_DIR" -maxdepth 1 -type f -name "$id-*.md" 2>/dev/null | sort | head -1)"
  [ -n "$file" ] || return 1
  printf '%s\n' "$file"
}

read_field() {
  local file="$1"
  local field="$2"
  awk -v key="- ${field}: " 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$file"
}

add_item() {
  local title="${1:-}"
  shift || true
  local id="" type="feature" status="candidate" priority="P2"
  local impact="medium" effort="medium" confidence="medium"
  local areas="" source_feedback=""
  local depends_on="none" required_roles="none" owner_lane="none"
  local contracts="none" parallel_safe="yes" approval_gate="none"

  if [ -z "$title" ]; then
    usage >&2
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --type) type="${2:-}"; shift 2 ;;
      --status) status="${2:-}"; shift 2 ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --impact) impact="${2:-}"; shift 2 ;;
      --effort) effort="${2:-}"; shift 2 ;;
      --confidence) confidence="${2:-}"; shift 2 ;;
      --areas) areas="${2:-}"; shift 2 ;;
      --source-feedback) source_feedback="${2:-}"; shift 2 ;;
      --depends-on) depends_on="${2:-}"; shift 2 ;;
      --required-roles) required_roles="${2:-}"; shift 2 ;;
      --owner-lane) owner_lane="${2:-}"; shift 2 ;;
      --contracts) contracts="${2:-}"; shift 2 ;;
      --parallel-safe) parallel_safe="${2:-}"; shift 2 ;;
      --approval-gate) approval_gate="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown add option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  roadmap_init
  [ -n "$id" ] || id="$(next_id RM "$ITEMS_DIR")"

  case "$id" in
    RM-[0-9][0-9][0-9][0-9]) ;;
    *)
      printf 'Invalid roadmap id: %s\nUse RM-0001 format.\n' "$id" >&2
      exit 1
      ;;
  esac

  local slug file
  slug="$(slugify "$title")"
  [ -n "$slug" ] || slug="item"
  file="$ITEMS_DIR/$id-$slug.md"

  if [ -e "$file" ] || item_file_for_id "$id" >/dev/null 2>&1; then
    printf 'Roadmap item already exists: %s\n' "$id" >&2
    exit 1
  fi

  {
    printf '# %s\n\n' "$title"
    printf '%s\n' "- ID: $id"
    printf '%s\n' "- Type: $type"
    printf '%s\n' "- Status: $status"
    printf '%s\n' "- Priority: $priority"
    printf '%s\n' "- Impact: $impact"
    printf '%s\n' "- Effort: $effort"
    printf '%s\n' "- Confidence: $confidence"
    printf '%s\n' "- Areas: ${areas:-none}"
    printf '%s\n' "- Depends on: ${depends_on:-none}"
    printf '%s\n' "- Required roles: ${required_roles:-none}"
    printf '%s\n' "- Owner lane: ${owner_lane:-none}"
    printf '%s\n' "- Contracts: ${contracts:-none}"
    printf '%s\n' "- Parallel safe: ${parallel_safe:-yes}"
    printf '%s\n' "- Approval gate: ${approval_gate:-none}"
    printf '%s\n' "- Source feedback: ${source_feedback:-none}"
    printf '%s\n' "- Related operator tasks: none"
    printf '%s\n' "- Related PRs/commits: none"
    printf '\n## Problem\n\n'
    printf 'Describe the user or product problem.\n\n'
    printf '## Rationale\n\n'
    printf 'Why this matters and what tradeoff it represents.\n\n'
    printf '## Acceptance Criteria\n\n'
    printf '%s\n' '- Observable outcome.'
    printf '%s\n\n' '- Validation expectation.'
    printf '## Dispatch Plan\n\n'
    printf '%s\n\n' '- Slice into lane-owned operator tasks when ready.'
    printf '## Progress\n\n'
    printf '%s\n' "- $(date -u '+%Y-%m-%dT%H:%M:%SZ') Created."
  } > "$file"

  printf '%s\n' "$file"
}

list_items() {
  local status_filter="" type_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) status_filter="${2:-}"; shift 2 ;;
      --type) type_filter="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown list option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  roadmap_init
  printf '%-10s %-12s %-10s %-8s %s\n' ID Status Type Priority Title
  printf '%-10s %-12s %-10s %-8s %s\n' -- ------ ---- -------- -----

  local file id status type priority title
  while IFS= read -r file; do
    id="$(read_field "$file" ID)"
    status="$(read_field "$file" Status)"
    type="$(read_field "$file" Type)"
    priority="$(read_field "$file" Priority)"
    title="$(sed -n '1s/^# //p' "$file")"
    [ -z "$status_filter" ] || [ "$status" = "$status_filter" ] || continue
    [ -z "$type_filter" ] || [ "$type" = "$type_filter" ] || continue
    printf '%-10s %-12s %-10s %-8s %s\n' "$id" "$status" "$type" "$priority" "$title"
  done < <(find "$ITEMS_DIR" -maxdepth 1 -type f -name 'RM-*.md' 2>/dev/null | sort)
}

status_items() {
  roadmap_init
  printf 'Roadmap: %s\n' "$ROADMAP_DIR"
  printf 'Items: %s\n' "$(find "$ITEMS_DIR" -maxdepth 1 -type f -name 'RM-*.md' 2>/dev/null | wc -l | tr -d ' ')"
  printf 'Inbox: %s\n' "$(find "$INBOX_DIR" -maxdepth 1 -type f -name 'FB-*.md' 2>/dev/null | wc -l | tr -d ' ')"
  printf '\nBy status:\n'
  find "$ITEMS_DIR" -maxdepth 1 -type f -name 'RM-*.md' 2>/dev/null \
    | while IFS= read -r file; do read_field "$file" Status; done \
    | sort | uniq -c | sed 's/^/  /'
  printf '\nBy type:\n'
  find "$ITEMS_DIR" -maxdepth 1 -type f -name 'RM-*.md' 2>/dev/null \
    | while IFS= read -r file; do read_field "$file" Type; done \
    | sort | uniq -c | sed 's/^/  /'
}

link_task() {
  local id="${1:-}"
  local task_slug="${2:-}"
  if [ -z "$id" ] || [ -z "$task_slug" ]; then
    usage >&2
    exit 1
  fi

  roadmap_init
  local file
  file="$(item_file_for_id "$id")" || {
    printf 'Roadmap item not found: %s\n' "$id" >&2
    exit 1
  }

  {
    printf '\n- %s Linked operator task `%s`.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$task_slug"
  } >> "$file"

  printf '%s\n' "$file"
}

pr_note() {
  local id="${1:-}"
  shift || true
  local feedback="none" task="none" why="" validation=""

  if [ -z "$id" ]; then
    usage >&2
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --feedback) feedback="${2:-}"; shift 2 ;;
      --task) task="${2:-}"; shift 2 ;;
      --why) why="${2:-}"; shift 2 ;;
      --validation) validation="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown pr-note option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  roadmap_init
  if ! item_file_for_id "$id" >/dev/null 2>&1; then
    printf 'warning: roadmap item not found locally: %s\n\n' "$id" >&2
  fi

  cat <<EOF
## Traceability

- Roadmap: $id
- Feedback: $feedback
- Operator task: $task

## Why

${why:-Short rationale for why this change exists.}

## Validation

${validation:-Commands, simulator checks, screenshots, or manual checks.}
EOF
}

command="${1:-}"
shift || true

case "$command" in
  init) roadmap_init; printf '%s\n' "$ROADMAP_DIR" ;;
  add) add_item "$@" ;;
  list) list_items "$@" ;;
  status) status_items ;;
  ready) list_items --status ready "$@" ;;
  link-task) link_task "$@" ;;
  pr-note) pr_note "$@" ;;
  -h|--help|"") usage ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
