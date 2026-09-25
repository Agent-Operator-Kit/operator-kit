#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/unit/lib.sh
source "$KIT_ROOT/tests/unit/lib.sh"

unit_bootstrap_project

cd "$UNIT_APP"

bash scripts/operator-workers.sh register smoke-task worker-a --kind task >/dev/null
if bash scripts/operator-workers.sh register smoke-task worker-a --kind task >/dev/null 2>&1; then
  unit_fail "duplicate worker registration should fail"
fi

bash scripts/operator-workers.sh check smoke-task worker-b
list_out="$(bash scripts/operator-workers.sh list smoke-task)"
assert_contains "$list_out" "worker-a"

bash scripts/operator-workers.sh clear smoke-task --worker worker-a >/dev/null
list_out="$(bash scripts/operator-workers.sh list smoke-task)"
assert_contains "$list_out" "none"

unit_pass "operator-workers"
