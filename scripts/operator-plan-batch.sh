#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

ROADMAP_DIR="$OPERATOR_DIR/roadmap"
ITEMS_DIR="$ROADMAP_DIR/items"
VIEWS_DIR="$ROADMAP_DIR/views"
STATUS_FILTER="ready"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-plan-batch.sh [--status ready]

Builds an operator-approved parallel dispatch plan from roadmap metadata.
It does not dispatch work. It writes OPERATOR_DIR/roadmap/views/batch-plan.md.

Roadmap fields used when present:
  Status, Depends on, Required roles, Owner lane, Contracts, Parallel safe,
  Approval gate
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status)
      STATUS_FILTER="${2:-}"
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

read_field() {
  local file="$1"
  local field="$2"
  awk -v key="- ${field}: " 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$file"
}

item_title() {
  sed -n '1s/^# //p' "$1"
}

item_file_for_id() {
  local id="$1"
  find "$ITEMS_DIR" -maxdepth 1 -type f -name "$id-*.md" 2>/dev/null | sort | head -1
}

status_for_id() {
  local id="$1"
  local file
  file="$(item_file_for_id "$id")"
  [ -n "$file" ] || return 1
  read_field "$file" "Status"
}

csv_tokens() {
  printf '%s\n' "$1" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sed '/^$/d; /^none$/d; /^TBD$/d'
}

deps_blocking() {
  local deps="$1"
  local dep status missing=0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    status="$(status_for_id "$dep" 2>/dev/null || true)"
    case "$status" in
      shipped|done|complete|completed) ;;
      *)
        printf '%s(%s) ' "$dep" "${status:-missing}"
        missing=1
        ;;
    esac
  done < <(csv_tokens "$deps")
  return "$missing"
}

append_line() {
  local file="$1"
  shift
  printf '%s\n' "$*" >> "$file"
}

mkdir -p "$VIEWS_DIR"
output="$VIEWS_DIR/batch-plan.md"
tmp="$(mktemp /tmp/operator-batch-plan.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

{
  printf '# Operator Batch Plan\n\n'
  printf '%s\n' "- Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' "- Status filter: $STATUS_FILTER"
  printf '%s\n\n' "- Mode: operator-approved planning only; no dispatch was performed."
  printf '## Parallel Dispatch Candidates\n\n'
} > "$tmp"

seen_lanes=" "
seen_contracts=" "
candidate_count=0
serialized_file="$(mktemp /tmp/operator-batch-serialized.XXXXXX)"
blocked_file="$(mktemp /tmp/operator-batch-blocked.XXXXXX)"
approval_file="$(mktemp /tmp/operator-batch-approval.XXXXXX)"
decision_file="$(mktemp /tmp/operator-batch-decision.XXXXXX)"
trap 'rm -f "$tmp" "$serialized_file" "$blocked_file" "$approval_file" "$decision_file"' EXIT

while IFS= read -r file; do
  [ -n "$file" ] || continue
  id="$(read_field "$file" ID)"
  status="$(read_field "$file" Status)"
  [ "$status" = "$STATUS_FILTER" ] || continue

  title="$(item_title "$file")"
  deps="$(read_field "$file" "Depends on")"
  roles="$(read_field "$file" "Required roles")"
  lane="$(read_field "$file" "Owner lane")"
  contracts="$(read_field "$file" "Contracts")"
  parallel_safe="$(read_field "$file" "Parallel safe")"
  approval_gate="$(read_field "$file" "Approval gate")"

  [ -n "$lane" ] || lane="none"
  [ -n "$roles" ] || roles="none"
  [ -n "$contracts" ] || contracts="none"
  [ -n "$parallel_safe" ] || parallel_safe="yes"
  [ -n "$approval_gate" ] || approval_gate="none"

  blocking="$(deps_blocking "$deps" || true)"
  if [ -n "$blocking" ]; then
    append_line "$blocked_file" "- \`$id\` $title: waits on $blocking"
    continue
  fi

  if [ "$lane" = "none" ]; then
    append_line "$decision_file" "- \`$id\` $title: owner lane missing; required roles: $roles"
    continue
  fi

  if [ "$approval_gate" != "none" ] && [ "$approval_gate" != "no" ]; then
    append_line "$approval_file" "- \`$id\` $title: approval gate \`$approval_gate\`"
    continue
  fi

  if [ "$parallel_safe" = "no" ]; then
    append_line "$serialized_file" "- \`$id\` $title: marked not parallel safe"
    continue
  fi

  if printf '%s' "$seen_lanes" | grep -q " $lane "; then
    append_line "$serialized_file" "- \`$id\` $title: lane \`$lane\` already has a candidate"
    continue
  fi

  conflict_contract=""
  while IFS= read -r contract; do
    [ -n "$contract" ] || continue
    if printf '%s' "$seen_contracts" | grep -q " $contract "; then
      conflict_contract="$contract"
      break
    fi
  done < <(csv_tokens "$contracts")
  if [ -n "$conflict_contract" ]; then
    append_line "$serialized_file" "- \`$id\` $title: contract \`$conflict_contract\` already has a candidate"
    continue
  fi

  append_line "$tmp" "- \`$id\` $title -> lane \`$lane\`; roles: $roles; contracts: $contracts"
  candidate_count=$((candidate_count + 1))
  seen_lanes="$seen_lanes$lane "
  while IFS= read -r contract; do
    [ -n "$contract" ] || continue
    seen_contracts="$seen_contracts$contract "
  done < <(csv_tokens "$contracts")
done < <(find "$ITEMS_DIR" -maxdepth 1 -type f -name 'RM-*.md' 2>/dev/null | sort)

if [ "$candidate_count" -eq 0 ]; then
  append_line "$tmp" "- none"
fi

{
  printf '\n## Needs Lane Decision\n\n'
  if [ -s "$decision_file" ]; then cat "$decision_file"; else printf '%s\n' "- none"; fi
  printf '\n## Needs Approval\n\n'
  if [ -s "$approval_file" ]; then cat "$approval_file"; else printf '%s\n' "- none"; fi
  printf '\n## Blocked By Dependencies\n\n'
  if [ -s "$blocked_file" ]; then cat "$blocked_file"; else printf '%s\n' "- none"; fi
  printf '\n## Serialized Or Conflict-Prone\n\n'
  if [ -s "$serialized_file" ]; then cat "$serialized_file"; else printf '%s\n' "- none"; fi
} >> "$tmp"

cp "$tmp" "$output"
cat "$output"
