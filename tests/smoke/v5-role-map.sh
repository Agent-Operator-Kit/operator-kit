#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
smoke_root="$(mktemp -d /tmp/aok-v5-role-map.XXXXXX)"
smoke_root="$(cd "$smoke_root" && pwd -P)"
trap 'rm -rf "$smoke_root"' EXIT

mkdir -p "$smoke_root/operator/catalog/roles" "$smoke_root/code"
cp "$KIT_ROOT"/templates/operator-workspace/catalog/roles/*.md \
  "$smoke_root/operator/catalog/roles/"

write_config() {
  local path="$1"
  local lanes="$2"
  cat > "$path" <<EOF
PROJECT_NAME="v5-role-map-smoke"
PROJECT_ROOT="$smoke_root"
CODE_DIR="$smoke_root/code"
OPERATOR_DIR="$smoke_root/operator"
TMUX_SESSION="v5-role-map-smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5"
OPERATOR_LANES='
$lanes
'
EOF
}

valid_lanes='operator|Codex Desktop|operator-kit-v5|codex/v5-integration|
lanes|Codex CLI|operator-kit-v5-rm-0001-lanes|codex/v5-rm-0001-lanes|codex
role-map|Codex CLI|operator-kit-v5-rm-0002-role-map|codex/v5-rm-0002-role-map|codex
control-graph|Codex CLI|operator-kit-v5-rm-0007-control-graph|codex/v5-rm-0007-control-graph|codex
scheduler|Codex CLI|operator-kit-v5-rm-0004-scheduler|codex/v5-rm-0004-scheduler|codex
loop-runner|Codex CLI|operator-kit-v5-rm-0003-loop-runner|codex/v5-rm-0003-loop-runner|codex
host-adapters|Codex CLI|operator-kit-v5-rm-0005-host-adapters|codex/v5-rm-0005-host-adapters|codex
design-flow|Claude Code|operator-kit-v5-rm-0006-design-flow|claude/v5-rm-0006-design-flow|claude'

config="$smoke_root/operator.config.env"
write_config "$config" "$valid_lanes"

role_map="$smoke_root/operator/catalog/role-map.json"
cp "$KIT_ROOT/templates/operator-workspace/catalog/role-map.json" "$role_map"
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate >/dev/null

OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" init --json \
  > "$smoke_root/init.json"
test -f "$role_map"
cmp -s "$smoke_root/init.json" "$role_map"

python3 - "$role_map" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    role_map = json.load(handle)

lanes = {lane["id"]: lane for lane in role_map["durableLanes"]}
assert set(lanes) == {
    "operator", "lanes", "role-map", "control-graph", "scheduler",
    "loop-runner", "host-adapters", "design-flow",
}
assert lanes["operator"]["authority"] == {"integrate": True, "manageQueue": True}
assert lanes["lanes"]["roleTemplateIds"] == ["high-risk-operations", "evals-testing"]
assert lanes["role-map"]["roleTemplateIds"] == ["api-contracts", "evals-testing"]
assert lanes["control-graph"]["roleTemplateIds"] == [
    "api-contracts", "data-storage", "observability", "evals-testing",
]
assert lanes["scheduler"]["roleTemplateIds"] == ["api-contracts", "evals-testing"]
assert lanes["loop-runner"]["roleTemplateIds"] == [
    "llm-runtime", "observability", "evals-testing",
]
assert lanes["host-adapters"]["roleTemplateIds"] == ["llm-runtime", "evals-testing"]
assert lanes["design-flow"]["roleTemplateIds"] == ["design-system", "evals-testing"]
assert role_map["featureInstances"] == []
assert {runner["id"] for runner in role_map["hostRunners"]} == {
    "codex-desktop", "codex-cli", "claude-code",
}
PY

OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate >/dev/null
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate --json \
  | grep -q '"valid": true'
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" show \
  | grep -q 'Durable lanes: 8'
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" show --json \
  > "$smoke_root/show.json"
cmp -s "$smoke_root/show.json" "$role_map"

python3 - "$role_map" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    role_map = json.load(handle)
lane = next(item for item in role_map["durableLanes"] if item["id"] == "role-map")
lane["roleTemplateIds"].append("knowledge-base")
lane["projectNote"] = "preserve this curated assignment"
role_map["featureInstances"].append({
    "kind": "feature-instance",
    "id": "api-contracts@FS-SMOKE",
    "featureId": "FS-SMOKE",
    "durableLaneId": "role-map",
    "roleTemplateId": "api-contracts",
    "hostRunnerId": "codex-cli",
    "worktree": "operator-kit-v5-fs-smoke-api-contracts",
    "branch": "codex/v5-fs-smoke-api-contracts",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(role_map, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" init >/dev/null
cp "$role_map" "$smoke_root/customized.json"
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" init >/dev/null
cmp -s "$smoke_root/customized.json" "$role_map"
python3 - "$role_map" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    role_map = json.load(handle)
lane = next(item for item in role_map["durableLanes"] if item["id"] == "role-map")
assert lane["roleTemplateIds"] == ["api-contracts", "evals-testing", "knowledge-base"]
assert lane["projectNote"] == "preserve this curated assignment"
assert role_map["featureInstances"] == [{
    "kind": "feature-instance",
    "id": "api-contracts@FS-SMOKE",
    "featureId": "FS-SMOKE",
    "durableLaneId": "role-map",
    "roleTemplateId": "api-contracts",
    "hostRunnerId": "codex-cli",
    "worktree": "operator-kit-v5-fs-smoke-api-contracts",
    "branch": "codex/v5-fs-smoke-api-contracts",
}]
PY

duplicate_branch_config="$smoke_root/duplicate-branch.config.env"
write_config "$duplicate_branch_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|app-worker|main|codex'
if OPERATOR_CONFIG="$duplicate_branch_config" \
  bash "$KIT_ROOT/scripts/operator-role-map.sh" init >/dev/null 2>&1; then
  printf 'expected duplicate branch ownership to fail\n' >&2
  exit 1
fi

duplicate_worktree_config="$smoke_root/duplicate-worktree.config.env"
write_config "$duplicate_worktree_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|app|codex/worker|codex'
if OPERATOR_CONFIG="$duplicate_worktree_config" \
  bash "$KIT_ROOT/scripts/operator-role-map.sh" init >/dev/null 2>&1; then
  printf 'expected duplicate worktree ownership to fail\n' >&2
  exit 1
fi

cp "$role_map" "$smoke_root/valid-role-map.json"
python3 - "$role_map" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    role_map = json.load(handle)
lane = next(item for item in role_map["durableLanes"] if item["id"] == "scheduler")
lane["roleTemplateIds"].append("unknown-role")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(role_map, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
if OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate >/dev/null 2>&1; then
  printf 'expected unknown role reference to fail\n' >&2
  exit 1
fi

cp "$smoke_root/valid-role-map.json" "$role_map"
python3 - "$role_map" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    role_map = json.load(handle)
lane = next(item for item in role_map["durableLanes"] if item["id"] == "scheduler")
lane["authority"]["integrate"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(role_map, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
if OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate >/dev/null 2>&1; then
  printf 'expected a second integrator to fail\n' >&2
  exit 1
fi

printf 'v5 role-map smoke ok: %s\n' "$smoke_root"
