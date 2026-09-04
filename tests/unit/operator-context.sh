#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/unit/lib.sh
source "$KIT_ROOT/tests/unit/lib.sh"

unit_bootstrap_project

cd "$UNIT_APP"

context_out="$(bash scripts/operator-context.sh)"
assert_contains "$context_out" "Project:"
assert_contains "$context_out" "Repo root"
assert_contains "$context_out" "Matched lane: operator"

json_out="$(bash scripts/operator-context.sh --json)"
assert_contains "$json_out" '"matched_lane":"operator"'

unit_pass "operator-context"
