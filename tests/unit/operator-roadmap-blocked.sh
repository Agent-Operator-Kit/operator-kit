#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/unit/lib.sh
source "$KIT_ROOT/tests/unit/lib.sh"

unit_bootstrap_project

cd "$UNIT_APP"

bash scripts/operator-roadmap.sh add "Blocked gate item" \
  --id RM-9001 --status blocked --approval-gate brand >/dev/null
bash scripts/operator-roadmap.sh add "Ready item" \
  --id RM-9002 --status ready --approval-gate none >/dev/null
bash scripts/operator-roadmap.sh add "Shipped gate item" \
  --id RM-9003 --status shipped --approval-gate brand >/dev/null

blocked_out="$(bash scripts/operator-roadmap.sh blocked)"
assert_contains "$blocked_out" "RM-9001"
assert_contains "$blocked_out" "brand"
assert_not_contains "$blocked_out" "RM-9002"
assert_not_contains "$blocked_out" "RM-9003"

summary_out="$(bash scripts/operator-summary.sh)"
assert_contains "$summary_out" "Blocked On Human"
assert_contains "$summary_out" "RM-9001"

unit_pass "operator-roadmap blocked"
