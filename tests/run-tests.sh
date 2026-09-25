#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"

run_glob() {
  local label="$1"
  local dir="$2"
  local script

  if [ ! -d "$dir" ]; then
    return 0
  fi

  printf '== %s ==\n' "$label"
  for script in "$dir"/*.sh; do
    [ -f "$script" ] || continue
    case "$(basename "$script")" in
      lib.sh) continue ;;
    esac
    bash "$script"
  done
}

case "$MODE" in
  unit) run_glob "unit" "$KIT_ROOT/tests/unit" ;;
  e2e) run_glob "e2e" "$KIT_ROOT/tests/e2e" ;;
  smoke) run_glob "smoke" "$KIT_ROOT/tests/smoke" ;;
  all)
    run_glob "unit" "$KIT_ROOT/tests/unit"
    run_glob "e2e" "$KIT_ROOT/tests/e2e"
    run_glob "smoke" "$KIT_ROOT/tests/smoke"
    ;;
  -h|--help)
    cat <<'USAGE'
Usage: bash tests/run-tests.sh [unit|e2e|smoke|all]
USAGE
    ;;
  *)
    printf 'Unknown mode: %s\n' "$MODE" >&2
    exit 1
    ;;
esac

printf 'tests ok: %s\n' "$MODE"
