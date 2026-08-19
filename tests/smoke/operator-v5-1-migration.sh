#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/operator-v5-1-migration.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/operator/features/FS-0001-work" "$TMP_ROOT/operator"/{authority,graph,host,loop}
cat > "$TMP_ROOT/repo/operator.config.env" <<EOF
PROJECT_NAME="smoke"
PROJECT_ROOT="$TMP_ROOT"
CODE_DIR="$TMP_ROOT"
OPERATOR_DIR="$TMP_ROOT/operator"
TMUX_SESSION="smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5"
OPERATOR_LANES='operator|Codex Desktop|repo|main|'
EOF
printf '%s\n' '{"id":"FS-0001","slug":"work","status":"active"}' > "$TMP_ROOT/operator/features/FS-0001-work/status.json"
printf '%s\n' '{}' > "$TMP_ROOT/operator/authority/control-graph-public-key.json"
printf '%s\n' '{}' > "$TMP_ROOT/operator/graph/definition.json"
printf '%s\n' '{}' > "$TMP_ROOT/operator/host/session.json"
printf '%s\n' '{}' > "$TMP_ROOT/operator/loop/state.json"

migrate() {
  OPERATOR_CONFIG="$TMP_ROOT/repo/operator.config.env" bash "$KIT_ROOT/scripts/operator-v5-1-migrate.sh" "$@"
}

migrate plan > "$TMP_ROOT/plan.json"
python3 - "$TMP_ROOT/plan.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["sourceVersion"] == "5"
assert value["targetVersion"] == "5.1"
assert value["keychainAction"] == "none"
assert set(value["signedRuntimeDirectoriesToArchive"]) == {"authority", "graph", "host", "loop"}
PY

if migrate apply >/dev/null 2>&1; then
  printf 'migration applied without authorization\n' >&2
  exit 1
fi
migrate apply --authorize MIGRATE_TO_V5_1_LOCAL_GRAPH > "$TMP_ROOT/result.json"
grep -q 'OPERATOR_KIT_VERSION="5.1"' "$TMP_ROOT/repo/operator.config.env"
test -f "$TMP_ROOT/operator/features/FS-0001-work/graph.json"
test -f "$TMP_ROOT/operator/migrations/to-v5.1-local-graph.json"
test ! -e "$TMP_ROOT/operator/authority"
test ! -e "$TMP_ROOT/operator/graph"
find "$TMP_ROOT/operator/archive/signed-v5" -type f -name control-graph-public-key.json | grep -q .
migrate apply --authorize MIGRATE_TO_V5_1_LOCAL_GRAPH | grep -q '"alreadyApplied": true'
printf 'operator v5.1 migration smoke ok\n'
