#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPERATOR_CONFIG="${OPERATOR_CONFIG:-$(pwd)/operator.config.env}" \
  bash "$SCRIPT_DIR/operator-system-map.sh" refresh >/dev/null
OPERATOR_CONFIG="${OPERATOR_CONFIG:-$(pwd)/operator.config.env}" \
  bash "$SCRIPT_DIR/operator-system-map.sh" recommend-lanes
