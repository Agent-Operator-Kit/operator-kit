#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/operator-v5-1-graph.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/operator/features/FS-0001-alpha" "$TMP_ROOT/operator/features/FS-0002-beta"
cat > "$TMP_ROOT/operator.config.env" <<EOF
PROJECT_NAME="smoke"
PROJECT_ROOT="$TMP_ROOT"
CODE_DIR="$TMP_ROOT"
OPERATOR_DIR="$TMP_ROOT/operator"
TMUX_SESSION="smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5.1"
OPERATOR_LANES='operator|Codex Desktop|repo|main|'
EOF
cat > "$TMP_ROOT/operator/features/FS-0001-alpha/status.json" <<'EOF'
{"id":"FS-0001","slug":"alpha","status":"active","claims":{"files":["shared"],"contracts":[],"resources":[],"surfaces":[]}}
EOF
cat > "$TMP_ROOT/operator/features/FS-0002-beta/status.json" <<'EOF'
{"id":"FS-0002","slug":"beta","status":"active","claims":{"files":["shared"],"contracts":[],"resources":[],"surfaces":[]}}
EOF

graph() {
  OPERATOR_CONFIG="$TMP_ROOT/operator.config.env" bash "$KIT_ROOT/scripts/operator-graph.sh" "$@"
}

graph init >/dev/null
graph add FS-0001 spec "Write specification" --lane operator --priority 100 >/dev/null
graph add FS-0001 build "Build feature" --lane backend --depends-on spec --priority 90 >/dev/null
graph add FS-0001 review "Review feature" --lane review --depends-on build --approval pending >/dev/null
graph add FS-0002 docs "Write docs" --lane docs --priority 80 >/dev/null

graph frontier --capacity 4 --json > "$TMP_ROOT/frontier.json"
python3 - "$TMP_ROOT/frontier.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert [(x["featureId"], x["node"]["id"]) for x in value["runnable"]] == [("FS-0001", "spec")]
assert any("conflict:feature-files" in x["reasons"] for x in value["excluded"] if x["node"]["id"] == "docs")
PY

graph set-state FS-0001 spec completed >/dev/null
graph set-state FS-0001 build completed >/dev/null
graph approve FS-0001 review approved >/dev/null
graph frontier FS-0001 --capacity 2 --json | grep -q '"id":"review"'

if graph depend FS-0001 spec review >/dev/null 2>&1; then
  printf 'cycle was accepted\n' >&2
  exit 1
fi
graph validate FS-0001 --json | grep -q '"ok":true'
printf 'operator v5.1 local graph smoke ok\n'
