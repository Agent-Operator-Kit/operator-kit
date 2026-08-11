#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH
unset PYTHONPATH PYTHONHOME

case "${OPERATOR_DESIGN_FLOW_PROVIDER_MODE:-}" in
  snapshot)
    [ "$#" -eq 0 ] || {
      printf 'Design-flow snapshot provider does not accept arguments.\n' >&2
      exit 2
    }
    set -- snapshot
    ;;
  mutation)
    [ "$#" -eq 0 ] || {
      printf 'Design-flow mutation provider does not accept arguments.\n' >&2
      exit 2
    }
    exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_design_provider.py" graph-mutation
    ;;
  feedback|"") ;;
  *)
    printf 'Unknown design-flow provider mode: %s\n' "$OPERATOR_DESIGN_FLOW_PROVIDER_MODE" >&2
    exit 2
    ;;
esac

if [ -z "${OPERATOR_DIR:-}" ]; then
  # shellcheck source=scripts/operator-lib.sh
  source "$SCRIPT_DIR/operator-lib.sh"
  operator_load_config
fi

exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_graph.py" --operator-dir "$OPERATOR_DIR" "$@"
