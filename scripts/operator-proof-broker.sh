#!/bin/bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [ "$SCRIPT_DIR" = "$SCRIPT_PATH" ]; then
  SCRIPT_DIR=.
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"

exec /usr/bin/python3 "$SCRIPT_DIR/operator_host.py" __broker "$@"
