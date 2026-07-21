#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

ROLE_MAP_PATH="$OPERATOR_DIR/catalog/role-map.json"
ROLES_DIR="$OPERATOR_DIR/catalog/roles"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-role-map.sh <command> [--json]

Commands:
  init
      Derive durable lanes and host runners from OPERATOR_LANES, preserving
      curated role assignments and feature instances in an existing map.
  show
      Show the current role map.
  validate
      Validate the role map, catalog references, authority, and ownership.

Options:
  --json
      Emit machine-readable JSON.
USAGE
}

command="${1:-}"
[ "$#" -eq 0 ] || shift
json_output="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json_output="true" ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$command" in
  init|show|validate) ;;
  -h|--help|"") usage; exit 0 ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required for the V5 role-map contract.\n' >&2
  exit 1
fi

python3 - "$command" "$json_output" "$ROLE_MAP_PATH" "$ROLES_DIR" "$OPERATOR_LANES" <<'PY'
import copy
import json
import os
import re
import sys
import tempfile
from pathlib import Path


command, json_output_raw, role_map_raw, roles_dir_raw, lanes_raw = sys.argv[1:]
json_output = json_output_raw == "true"
role_map_path = Path(role_map_raw)
roles_dir = Path(roles_dir_raw)

DEFAULT_ASSIGNMENTS = {
    "operator": [],
    "lanes": ["high-risk-operations", "evals-testing"],
    "role-map": ["api-contracts", "evals-testing"],
    "control-graph": ["api-contracts", "data-storage", "observability", "evals-testing"],
    "scheduler": ["api-contracts", "evals-testing"],
    "loop-runner": ["llm-runtime", "observability", "evals-testing"],
    "host-adapters": ["llm-runtime", "evals-testing"],
    "design-flow": ["design-system", "evals-testing"],
}


class ContractError(Exception):
    pass


def fail(message):
    raise ContractError(message)


def slugify(value):
    slug = re.sub(r"[^a-z0-9]+", "-", value.strip().lower()).strip("-")
    return slug or "host-runner"


def parse_config_lanes(raw):
    lanes = []
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        fields = line.split("|")
        if len(fields) < 4:
            fail(f"OPERATOR_LANES line {line_number} must have at least four pipe-delimited fields")
        lane_id, tool, worktree, branch = (field.strip() for field in fields[:4])
        if not all((lane_id, tool, worktree, branch)):
            fail(f"OPERATOR_LANES line {line_number} requires lane id, tool, worktree, and branch")
        lanes.append({
            "id": lane_id,
            "tool": tool,
            "worktree": worktree,
            "branch": branch,
        })
    if not lanes:
        fail("OPERATOR_LANES does not contain any durable lanes")
    return lanes


def read_json(path):
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        fail(f"Role map not found: {path}; run init first")
    except json.JSONDecodeError as error:
        fail(f"Invalid role-map JSON at line {error.lineno}, column {error.colno}: {error.msg}")
    if not isinstance(payload, dict):
        fail("Role map root must be a JSON object")
    return payload


def catalog_roles():
    if not roles_dir.is_dir():
        fail(f"Role catalog not found: {roles_dir}")
    roles = {}
    for path in sorted(roles_dir.glob("*.md")):
        if path.name in {"_template.md", "README.md"}:
            continue
        declared_id = None
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"^- ID:\s*(\S+)\s*$", line.rstrip("\n"))
                if match:
                    declared_id = match.group(1)
                    break
        if not declared_id:
            fail(f"Catalog role has no '- ID:' declaration: {path}")
        if declared_id != path.stem:
            fail(f"Catalog role id '{declared_id}' does not match filename '{path.stem}'")
        if declared_id in roles:
            fail(f"Duplicate catalog role id: {declared_id}")
        roles[declared_id] = path
    if not roles:
        fail(f"Role catalog contains no role templates: {roles_dir}")
    return roles


def require_list(payload, key):
    value = payload.get(key)
    if not isinstance(value, list):
        fail(f"'{key}' must be a JSON array")
    return value


def require_object(value, label):
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_string(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def unique_index(items, key, label):
    indexed = {}
    for position, item in enumerate(items):
        require_object(item, f"{label}[{position}]")
        value = require_string(item.get(key), f"{label}[{position}].{key}")
        if value in indexed:
            fail(f"Duplicate {label} {key}: {value}")
        indexed[value] = item
    return indexed


def validate_payload(payload, config_lanes):
    if payload.get("kind") != "operator-role-map":
        fail("Role map kind must be 'operator-role-map'")
    if payload.get("schemaVersion") != 1:
        fail("Role map schemaVersion must be 1")

    role_templates = require_list(payload, "roleTemplates")
    durable_lanes = require_list(payload, "durableLanes")
    feature_instances = require_list(payload, "featureInstances")
    host_runners = require_list(payload, "hostRunners")

    roles = catalog_roles()
    role_index = unique_index(role_templates, "id", "roleTemplates")
    for role_id, role in role_index.items():
        if role.get("kind") != "role-template":
            fail(f"roleTemplates '{role_id}' kind must be 'role-template'")
        expected_ref = f"roles/{role_id}.md"
        if role.get("catalogRef") != expected_ref:
            fail(f"Role template '{role_id}' catalogRef must be '{expected_ref}'")
        if role_id not in roles:
            fail(f"Unknown catalog role template: {role_id}")

    for role_id in roles:
        if role_id not in role_index:
            fail(f"Catalog role is missing from roleTemplates: {role_id}")

    runner_index = unique_index(host_runners, "id", "hostRunners")
    for runner_id, runner in runner_index.items():
        if runner.get("kind") != "host-runner":
            fail(f"hostRunner '{runner_id}' kind must be 'host-runner'")
        require_string(runner.get("tool"), f"hostRunner '{runner_id}'.tool")

    lane_index = unique_index(durable_lanes, "id", "durableLanes")
    expected_index = unique_index(config_lanes, "id", "OPERATOR_LANES")
    if set(lane_index) != set(expected_index):
        fail("durableLanes ids do not match OPERATOR_LANES; run init")

    branch_owners = {}
    worktree_owners = {}
    integrators = []
    queue_managers = []

    def claim(owner, branch, worktree):
        if branch in branch_owners:
            fail(f"Duplicate branch ownership: '{branch}' is owned by {branch_owners[branch]} and {owner}")
        if worktree in worktree_owners:
            fail(f"Duplicate worktree ownership: '{worktree}' is owned by {worktree_owners[worktree]} and {owner}")
        branch_owners[branch] = owner
        worktree_owners[worktree] = owner

    for lane_id, lane in lane_index.items():
        if lane.get("kind") != "durable-lane":
            fail(f"durableLane '{lane_id}' kind must be 'durable-lane'")
        expected = expected_index[lane_id]
        for field in ("tool", "worktree", "branch"):
            actual = require_string(lane.get(field), f"durableLane '{lane_id}'.{field}")
            if actual != expected[field]:
                fail(f"durableLane '{lane_id}'.{field} does not match OPERATOR_LANES; run init")
        runner_id = require_string(lane.get("hostRunnerId"), f"durableLane '{lane_id}'.hostRunnerId")
        if runner_id not in runner_index:
            fail(f"durableLane '{lane_id}' references unknown host runner: {runner_id}")
        if runner_index[runner_id]["tool"] != lane["tool"]:
            fail(f"durableLane '{lane_id}' tool does not match host runner '{runner_id}'")

        assigned_roles = lane.get("roleTemplateIds")
        if not isinstance(assigned_roles, list):
            fail(f"durableLane '{lane_id}'.roleTemplateIds must be a JSON array")
        if len(assigned_roles) != len(set(assigned_roles)):
            fail(f"durableLane '{lane_id}' has duplicate role assignments")
        for role_id in assigned_roles:
            if not isinstance(role_id, str) or role_id not in role_index:
                fail(f"durableLane '{lane_id}' references unknown role: {role_id}")

        authority = require_object(lane.get("authority"), f"durableLane '{lane_id}'.authority")
        manage_queue = authority.get("manageQueue")
        integrate = authority.get("integrate")
        if not isinstance(manage_queue, bool) or not isinstance(integrate, bool):
            fail(f"durableLane '{lane_id}' authority values must be booleans")
        if manage_queue:
            queue_managers.append(lane_id)
        if integrate:
            integrators.append(lane_id)
        claim(f"durable lane '{lane_id}'", lane["branch"], lane["worktree"])

    if queue_managers != ["operator"]:
        fail("Only durable lane 'operator' may manage the queue")
    if integrators != ["operator"]:
        fail("Only durable lane 'operator' may integrate")

    instance_index = unique_index(feature_instances, "id", "featureInstances")
    for instance_id, instance in instance_index.items():
        if instance.get("kind") != "feature-instance":
            fail(f"featureInstance '{instance_id}' kind must be 'feature-instance'")
        require_string(instance.get("featureId"), f"featureInstance '{instance_id}'.featureId")
        lane_id = require_string(instance.get("durableLaneId"), f"featureInstance '{instance_id}'.durableLaneId")
        role_id = require_string(instance.get("roleTemplateId"), f"featureInstance '{instance_id}'.roleTemplateId")
        runner_id = require_string(instance.get("hostRunnerId"), f"featureInstance '{instance_id}'.hostRunnerId")
        branch = require_string(instance.get("branch"), f"featureInstance '{instance_id}'.branch")
        worktree = require_string(instance.get("worktree"), f"featureInstance '{instance_id}'.worktree")
        if lane_id not in lane_index:
            fail(f"featureInstance '{instance_id}' references unknown durable lane: {lane_id}")
        if role_id not in role_index:
            fail(f"featureInstance '{instance_id}' references unknown role: {role_id}")
        if runner_id not in runner_index:
            fail(f"featureInstance '{instance_id}' references unknown host runner: {runner_id}")
        claim(f"feature instance '{instance_id}'", branch, worktree)


def build_payload(config_lanes):
    existing = read_json(role_map_path) if role_map_path.exists() else {}
    existing_lanes = {
        item.get("id"): item
        for item in existing.get("durableLanes", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    existing_roles = {
        item.get("id"): item
        for item in existing.get("roleTemplates", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    existing_runners = {
        item.get("id"): item
        for item in existing.get("hostRunners", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }

    catalog = catalog_roles()
    role_templates = []
    for role_id in sorted(catalog):
        role = copy.deepcopy(existing_roles.get(role_id, {}))
        role.update({
            "kind": "role-template",
            "id": role_id,
            "catalogRef": f"roles/{role_id}.md",
        })
        role_templates.append(role)

    runners_by_id = {}
    durable_lanes = []
    for derived in config_lanes:
        lane_id = derived["id"]
        runner_id = slugify(derived["tool"])
        runner = copy.deepcopy(existing_runners.get(runner_id, {}))
        runner.update({
            "kind": "host-runner",
            "id": runner_id,
            "tool": derived["tool"],
        })
        runners_by_id[runner_id] = runner

        lane = copy.deepcopy(existing_lanes.get(lane_id, {}))
        if "roleTemplateIds" not in lane:
            lane["roleTemplateIds"] = DEFAULT_ASSIGNMENTS.get(lane_id, [])
        if "authority" not in lane:
            is_operator = lane_id == "operator"
            lane["authority"] = {"manageQueue": is_operator, "integrate": is_operator}
        lane.update({
            "kind": "durable-lane",
            "id": lane_id,
            "tool": derived["tool"],
            "hostRunnerId": runner_id,
            "worktree": derived["worktree"],
            "branch": derived["branch"],
        })
        durable_lanes.append(lane)

    payload = copy.deepcopy(existing)
    payload.update({
        "kind": "operator-role-map",
        "schemaVersion": 1,
        "durableLanes": sorted(durable_lanes, key=lambda item: item["id"]),
        "roleTemplates": role_templates,
        "featureInstances": copy.deepcopy(existing.get("featureInstances", [])),
        "hostRunners": sorted(runners_by_id.values(), key=lambda item: item["id"]),
    })
    return payload


def write_atomic(payload):
    role_map_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".role-map.", suffix=".json.tmp", dir=role_map_path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_path, role_map_path)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


def emit_json(payload):
    print(json.dumps(payload, indent=2, sort_keys=True))


try:
    config_lanes = parse_config_lanes(lanes_raw)
    if command == "init":
        payload = build_payload(config_lanes)
        validate_payload(payload, config_lanes)
        write_atomic(payload)
        if json_output:
            emit_json(payload)
        else:
            print(role_map_path)
    elif command == "show":
        payload = read_json(role_map_path)
        if json_output:
            emit_json(payload)
        else:
            print("# Operator V5 Role Map")
            print()
            print(f"- Path: `{role_map_path}`")
            print(f"- Durable lanes: {len(payload.get('durableLanes', []))}")
            print(f"- Role templates: {len(payload.get('roleTemplates', []))}")
            print(f"- Feature instances: {len(payload.get('featureInstances', []))}")
            print(f"- Host runners: {len(payload.get('hostRunners', []))}")
    elif command == "validate":
        payload = read_json(role_map_path)
        validate_payload(payload, config_lanes)
        if json_output:
            emit_json({"path": str(role_map_path), "valid": True})
        else:
            print(f"role map valid: {role_map_path}")
except ContractError as error:
    if json_output:
        emit_json({"error": str(error), "path": str(role_map_path), "valid": False})
    else:
        print(f"role map invalid: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
