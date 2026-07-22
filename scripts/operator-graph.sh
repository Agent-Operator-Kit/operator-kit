#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${OPERATOR_DIR:-}" ]; then
  # shellcheck source=scripts/operator-lib.sh
  source "$SCRIPT_DIR/operator-lib.sh"
  operator_load_config
fi

exec python3 "$SCRIPT_DIR/operator_graph.py" --operator-dir "$OPERATOR_DIR" "$@"
