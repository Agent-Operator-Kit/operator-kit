#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

CATALOG_DIR="$OPERATOR_DIR/catalog"
ROLES_DIR="$CATALOG_DIR/roles"
PATTERNS_DIR="$CATALOG_DIR/patterns"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-catalog.sh <command> [args]

Commands:
  init
      Create the V2 role and architecture-pattern catalog workspace.
  list [roles|patterns]
      List available catalog entries.
  show <roles|patterns> <id>
      Print one catalog entry.
  recommend
      Print a short catalog-driven lane recommendation prompt.
USAGE
}

catalog_init() {
  mkdir -p "$ROLES_DIR" "$PATTERNS_DIR"

  if [ ! -f "$CATALOG_DIR/README.md" ]; then
    cat > "$CATALOG_DIR/README.md" <<'EOF'
# Operator Catalog

V2 Operator Kit uses this local catalog to connect lanes, role templates,
architecture patterns, approved tools, validation recipes, and task contracts.

The source kit installs starter entries, but this project-local catalog should
be curated over time. Project-approved patterns win over generic defaults.
EOF
  fi

  if [ ! -f "$ROLES_DIR/_template.md" ]; then
    cat > "$ROLES_DIR/_template.md" <<'EOF'
# <Role Template>

- ID: role-id
- Production layers: frontend, backend, data, auth, release, observability
- Durable lane candidate: no
- Preferred active lane: TBD
- Contract refs: pattern-id

## Purpose

Describe the specialist responsibility.

## Owned Surfaces

- TBD

## Read-Only Surfaces

- TBD

## Approved Patterns And Tools

- TBD

## Validation

- TBD

## Escalation Gates

- credentials, destructive migrations, production release, regulated or safety-critical behavior
EOF
  fi

  if [ ! -f "$PATTERNS_DIR/_template.md" ]; then
    cat > "$PATTERNS_DIR/_template.md" <<'EOF'
# <Architecture Pattern>

- ID: pattern-id
- Applies to roles: role-id
- Default status: candidate-approved

## Use When

- TBD

## Approved Packages And Repos

- TBD

## Consistency Rules

- TBD

## Validation

- TBD
EOF
  fi
}

catalog_dir_for_type() {
  case "${1:-}" in
    roles|role) printf '%s\n' "$ROLES_DIR" ;;
    patterns|pattern) printf '%s\n' "$PATTERNS_DIR" ;;
    *)
      printf 'Unknown catalog type: %s\n' "${1:-<unset>}" >&2
      printf 'Use: roles or patterns\n' >&2
      return 1
      ;;
  esac
}

list_entries() {
  local type="${1:-roles}"
  local dir
  dir="$(catalog_dir_for_type "$type")"
  catalog_init
  find "$dir" -maxdepth 1 -type f -name '*.md' \
    ! -name '_template.md' ! -name 'README.md' \
    | sed 's#.*/##; s#\.md$##' \
    | sort
}

show_entry() {
  local type="${1:-}"
  local id="${2:-}"
  local dir file
  if [ -z "$type" ] || [ -z "$id" ]; then
    usage >&2
    exit 1
  fi
  dir="$(catalog_dir_for_type "$type")"
  file="$dir/$id.md"
  if [ ! -f "$file" ]; then
    printf 'Catalog entry not found: %s/%s\n' "$type" "$id" >&2
    exit 1
  fi
  cat "$file"
}

recommend_prompt() {
  catalog_init
  cat <<EOF
# Operator V2 Catalog Recommendation

Use the system map plus catalog to choose:

- durable lanes for long-lived, high-context, or high-risk ownership
- role overlays for specialist work that does not need a permanent worktree
- architecture patterns that match the role contract
- validation recipes and approval gates before dispatch

Catalog: $CATALOG_DIR

Roles:
$(list_entries roles | sed 's/^/- /')

Patterns:
$(list_entries patterns | sed 's/^/- /')
EOF
}

command="${1:-}"
shift || true

case "$command" in
  init) catalog_init; printf '%s\n' "$CATALOG_DIR" ;;
  list) list_entries "${1:-roles}" ;;
  show) show_entry "$@" ;;
  recommend) recommend_prompt ;;
  -h|--help|"") usage ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
