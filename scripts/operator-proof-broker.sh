#!/bin/bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [ "$SCRIPT_DIR" = "$SCRIPT_PATH" ]; then
  SCRIPT_DIR=.
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"

# The one-shot signer shares the trusted host implementation and must establish
# the same pre-import boundary independently. Ignore caller Python startup
# configuration and prevent sibling graph/keychain helpers from resolving
# attacker-controlled executables before host policy can run.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH
unset PYTHONPATH PYTHONHOME

if [ "${OPERATOR_DESIGN_FLOW_BROKER:-}" = "1" ]; then
  [ "$#" -eq 0 ] || {
    printf 'Design-flow proof broker does not accept arguments.\n' >&2
    exit 2
  }
  exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_host.py" __design_broker
fi

exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_host.py" __broker "$@"
