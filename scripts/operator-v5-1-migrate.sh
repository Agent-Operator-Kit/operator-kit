#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_v5_1_migrate.py" \
  --operator-dir "$OPERATOR_DIR" \
  --config "$(operator_config_file)" "$@"
