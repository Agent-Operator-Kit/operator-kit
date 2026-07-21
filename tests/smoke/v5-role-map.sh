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

valid_lanes='operator|Codex Desktop|operator-kit-v5-integration|codex/operator-v5-integration|
lanes|Codex CLI|operator-kit-v5-rm-0001-lanes|codex/v5-rm-0001-lanes|codex
role-map|Codex CLI|operator-kit-v5-rm-0002-role-map|codex/v5-rm-0002-role-map|codex
control-graph|Codex CLI|operator-kit-v5-rm-0007-control-graph|codex/v5-rm-0007-control-graph|codex
scheduler|Codex CLI|operator-kit-v5-rm-0004-scheduler|codex/v5-rm-0004-scheduler|codex
loop-runner|Codex CLI|operator-kit-v5-rm-0003-loop-runner|codex/v5-rm-0003-loop-runner|codex
host-adapters|Codex CLI|operator-kit-v5-rm-0005-host-adapters|codex/v5-rm-0005-host-adapters|codex
design-flow|Claude Code|operator-kit-v5-rm-0006-design-flow|codex/v5-rm-0006-design-flow|claude'

config="$smoke_root/operator.config.env"
write_config "$config" "$valid_lanes"

role_map="$smoke_root/operator/catalog/role-map.json"
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" init --json \
  > "$smoke_root/init.json"
test -f "$role_map"
cmp -s "$smoke_root/init.json" "$role_map"
cmp -s "$KIT_ROOT/templates/operator-workspace/catalog/role-map.json" "$role_map"
OPERATOR_CONFIG="$config" bash "$KIT_ROOT/scripts/operator-role-map.sh" validate >/dev/null

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
assert lanes["operator"]["branch"] == "codex/operator-v5-integration"
assert lanes["operator"]["worktree"] == "operator-kit-v5-integration"
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
assert lanes["design-flow"]["branch"] == "codex/v5-rm-0006-design-flow"
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

expect_init_json_failure() {
  local invalid_config="$1"
  local label="$2"
  cp "$role_map" "$smoke_root/before-invalid-init.json"
  if OPERATOR_CONFIG="$invalid_config" \
    bash "$KIT_ROOT/scripts/operator-role-map.sh" init --json \
      > "$smoke_root/failure.json" 2> "$smoke_root/failure.err"; then
    printf 'expected init failure for %s\n' "$label" >&2
    exit 1
  fi
  cmp -s "$smoke_root/before-invalid-init.json" "$role_map"
  python3 - "$smoke_root/failure.json" "$smoke_root/failure.err" "$label" <<'PY'
import json
import sys

stdout_path, stderr_path, label = sys.argv[1:]
with open(stdout_path, encoding="utf-8") as handle:
    result = json.load(handle)
assert result["valid"] is False, label
assert isinstance(result.get("error"), str) and result["error"], label
combined = open(stdout_path, encoding="utf-8").read() + open(stderr_path, encoding="utf-8").read()
assert "Traceback" not in combined, label
PY
}

invalid_config="$smoke_root/invalid-topology.config.env"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
Bad_ID|Codex CLI|app-worker|codex/worker|codex'
expect_init_json_failure "$invalid_config" "non-normalized durable-lane id"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|app-worker|-bad|codex'
expect_init_json_failure "$invalid_config" "option-like branch"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|app-worker|codex//worker|codex'
expect_init_json_failure "$invalid_config" "invalid Git ref"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|/tmp/app-worker|codex/worker|codex'
expect_init_json_failure "$invalid_config" "absolute worktree"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|../app-worker|codex/worker|codex'
expect_init_json_failure "$invalid_config" "worktree traversal"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|nested/app-worker|codex/worker|codex'
expect_init_json_failure "$invalid_config" "worktree separator"

write_config "$invalid_config" 'operator|Codex Desktop|app|main|
worker|Codex CLI|App-Worker|codex/worker|codex'
expect_init_json_failure "$invalid_config" "non-normalized worktree"

control_lanes=$'operator|Codex Desktop|app|main|\nworker|Codex CLI|app-worker|codex/bad\001branch|codex'
write_config "$invalid_config" "$control_lanes"
expect_init_json_failure "$invalid_config" "branch control character"

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

python3 - "$role_map" "$KIT_ROOT/scripts/operator-role-map.sh" "$config" <<'PY'
import copy
import json
import os
import subprocess
import sys

role_map_path, script_path, config_path = sys.argv[1:]


def load():
    with open(role_map_path, encoding="utf-8") as handle:
        return json.load(handle)


def write(payload):
    with open(role_map_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def run(command):
    env = os.environ.copy()
    env["OPERATOR_CONFIG"] = config_path
    result = subprocess.run(
        ["bash", script_path, command, "--json"],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    payload = json.loads(result.stdout)
    assert payload["valid"] is False
    assert isinstance(payload.get("error"), str) and payload["error"]
    assert "Traceback" not in result.stdout + result.stderr


baseline = load()
malformed_cases = []

payload = copy.deepcopy(baseline)
payload["durableLanes"] = None
malformed_cases.append(("non-array durableLanes", payload))

payload = copy.deepcopy(baseline)
payload["roleTemplates"][0] = "not-an-object"
malformed_cases.append(("malformed roleTemplates element", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"] = {}
malformed_cases.append(("non-array featureInstances", payload))

payload = copy.deepcopy(baseline)
payload["hostRunners"][0] = ["not-an-object"]
malformed_cases.append(("malformed hostRunners element", payload))

payload = copy.deepcopy(baseline)
lane = next(item for item in payload["durableLanes"] if item["id"] == "role-map")
lane["roleTemplateIds"] = [["api-contracts"]]
malformed_cases.append(("unhashable preserved role value", payload))

for label, payload in malformed_cases:
    write(payload)
    before = open(role_map_path, "rb").read()
    run("init")
    after = open(role_map_path, "rb").read()
    assert after == before, f"init overwrote malformed preservation case: {label}"

feature_cases = []

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["id"] = "bad\x01id"
feature_cases.append(("feature id control character", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["id"] = "bad/id"
feature_cases.append(("non-normalized feature id", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["branch"] = "-bad"
feature_cases.append(("option-like feature branch", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["branch"] = "codex//bad"
feature_cases.append(("invalid feature Git ref", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["branch"] = "codex/bad\x01branch"
feature_cases.append(("feature branch control character", payload))

for unsafe_worktree in (
    "/tmp/feature-worktree",
    "../feature-worktree",
    "nested/feature-worktree",
    "Feature-Worktree",
    "feature\x01worktree",
):
    payload = copy.deepcopy(baseline)
    payload["featureInstances"][0]["worktree"] = unsafe_worktree
    feature_cases.append((f"unsafe feature worktree: {unsafe_worktree!r}", payload))

payload = copy.deepcopy(baseline)
payload["featureInstances"][0]["roleTemplateId"] = "auth-permissions"
feature_cases.append(("feature role not assigned to durable lane", payload))

for label, payload in feature_cases:
    write(payload)
    try:
        run("validate")
    except AssertionError as error:
        raise AssertionError(label) from error

write(baseline)
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
