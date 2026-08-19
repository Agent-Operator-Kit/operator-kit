#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

# Stable exits from operator_model_selector.py:
#   0 = valid recommendation, validation, or replay
#   3 = valid off/needs_override advisory receipt
#   2 = invalid usage, input, or I/O
exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_model_selector.py" \
  --operator-dir "$OPERATOR_DIR" "$@"
