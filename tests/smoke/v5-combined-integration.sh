#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-combined.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

repo="$TMP_ROOT/project/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null

# Run the graph, scheduler, loop, trusted host/containment, role-map, and design
# matrices against the runtime copied into a real installed project.
export OPERATOR_KIT_TEST_ROOT="$repo"
bash "$KIT_ROOT/tests/smoke/operator-v5-control-graph.sh"
bash "$KIT_ROOT/tests/smoke/operator-v5-scheduler.sh"
bash "$KIT_ROOT/tests/smoke/operator-v5-loop.sh"
bash "$KIT_ROOT/tests/smoke/v5-host-runners.sh"
export OPERATOR_DESIGN_FLOW_TEST_OPERATOR_DIR="$TMP_ROOT/project/operator"
bash "$KIT_ROOT/tests/smoke/v5-design-flow.sh"
unset OPERATOR_DESIGN_FLOW_TEST_OPERATOR_DIR
bash "$KIT_ROOT/tests/smoke/v5-design-production.sh"
bash "$KIT_ROOT/tests/smoke/v5-role-map.sh"
unset OPERATOR_KIT_TEST_ROOT

bash "$KIT_ROOT/tests/smoke/v5-lane-policy.sh"
bash "$KIT_ROOT/tests/smoke/v5-final-install-flow.sh"
bash "$KIT_ROOT/tests/smoke/operator-v5-migration.sh"
bash "$KIT_ROOT/tests/smoke/operator-version-channels.sh"
bash "$KIT_ROOT/tests/smoke/v3-host-adapters.sh"
bash "$KIT_ROOT/tests/smoke/codex-plugin-package.sh"

printf 'v5 combined installed-project integration matrix ok\n'
