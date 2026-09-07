#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/unit/lib.sh
source "$KIT_ROOT/tests/unit/lib.sh"

unit_bootstrap_project

cd "$UNIT_APP"

bash scripts/operator-adapter-check.sh >/dev/null

printf 'operator/\n' >> .gitignore
if bash scripts/operator-adapter-check.sh >/dev/null 2>&1; then
  unit_fail "adapter-check should fail when operator/ gitignore is present"
fi

unit_pass "operator-adapter-check"
