#!/bin/bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [ "$SCRIPT_DIR" = "$SCRIPT_PATH" ]; then
  SCRIPT_DIR=.
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"

# Python must not process caller-controlled startup paths before the trusted
# host boundary can reject runtime injection. Keep supported tool locations on
# a fixed, system-first path for graph helpers and later host subprocesses.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH
unset PYTHONPATH PYTHONHOME

exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_host.py" "$@"
