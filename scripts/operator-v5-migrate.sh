#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)"
CONFIG_FILE="${OPERATOR_CONFIG:-${PWD}/operator.config.env}"
PYTHON_BIN="/usr/bin/python3"
TRUSTED_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

if [ ! -x "$PYTHON_BIN" ]; then
  printf 'The pinned system Python interpreter is unavailable: %s\n' "$PYTHON_BIN" >&2
  exit 1
fi

if [ "${1:-}" = "--dry-run" ]; then
  shift
  set -- plan "$@"
fi

# Ignore Python startup configuration before importing any migration or graph
# code, and prevent graph lock identity probes from resolving caller PATH
# shims. -E/-s retain the invoked script directory for sibling-module loading.
PATH="$TRUSTED_PATH"
export PATH
unset PYTHONPATH PYTHONHOME

exec "$PYTHON_BIN" -E -s "$SCRIPT_DIR/operator_v5_migrate.py" --config "$CONFIG_FILE" "$@"
