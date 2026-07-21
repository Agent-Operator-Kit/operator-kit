#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH_SCRIPT="$KIT_ROOT/scripts/operator-graph.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-control-graph.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'operator v5 control graph smoke failed: %s\n' "$1" >&2
  exit 1
}

expect_error() {
  local expected_status="$1"
  local expected_code="$2"
  shift 2
  local output="$TMP_ROOT/error-out.json"
  local error="$TMP_ROOT/error.json"
  local command_status
  set +e
  "$@" >"$output" 2>"$error"
  command_status="$?"
  set -e
  [ "$command_status" -eq "$expected_status" ] || {
    cat "$output" >&2
    cat "$error" >&2
    fail "expected exit $expected_status, got $command_status: $*"
  }
  ! grep -q 'Traceback' "$error" || fail "command emitted a traceback: $*"
  python3 - "$error" "$expected_code" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
assert value["ok"] is False, value
assert value["error"]["code"] == sys.argv[2], value
PY
}

copy_state() {
  local source="$1"
  local target="$2"
  mkdir -p "$target/graph"
  cp "$source/graph/definition.json" "$target/graph/definition.json"
  cp "$source/graph/projection.json" "$target/graph/projection.json"
  cp "$source/graph/events.jsonl" "$target/graph/events.jsonl"
}

write_bindings() {
  local operator_dir="$1"
  mkdir -p "$operator_dir/graph/bindings"
  chmod 700 "$operator_dir/graph/bindings"
  python3 - "$operator_dir/graph/bindings" <<'PY'
import json, os, sys
from pathlib import Path

root = Path(sys.argv[1])
bindings = {
    "operator": ({"type": "operator", "id": "control"},
                 ["graph-init", "graph-replace", "replay-repair", "sweep", "test-injection", "transition"], []),
    "system": ({"type": "system", "id": "heartbeat"},
               ["graph-init", "graph-replace", "replay-repair", "sweep", "test-injection", "transition"], []),
    "human": ({"type": "human", "id": "authorized-human"}, ["gate-decision"], []),
    "lane-a": ({"type": "lane", "id": "worker-a", "laneNodeId": "lane-a"},
               ["lease", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
    "lane-a-test": ({"type": "lane", "id": "worker-a-test", "laneNodeId": "lane-a"},
                    ["lease", "test-injection", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
    "lane-a-recovery": ({"type": "lane", "id": "worker-a-recovery", "laneNodeId": "lane-a"},
                        ["lease", "test-injection", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
    "lane-b": ({"type": "lane", "id": "worker-b", "laneNodeId": "lane-b"},
               ["graph-init", "graph-replace", "lease", "transition"], [{"scope": "lane:b", "laneNodeId": "lane-b"}]),
    "host": ({"type": "host", "id": "codex-cli", "hostRunnerId": "codex-cli"},
             ["graph-init", "graph-replace", "lease", "sweep", "transition"], [{"scope": "host:a", "laneNodeId": "lane-a"}]),
    "fake-human": ({"type": "host", "id": "fake", "hostRunnerId": "codex-cli"}, ["gate-decision"], []),
    "human-overpowered": ({"type": "human", "id": "human-overpowered"},
                          ["gate-decision", "graph-init", "graph-replace"], []),
    "subagent": ({"type": "subagent", "id": "child"}, ["graph-init", "graph-replace", "transition"], []),
}
for binding_id, (subject, capabilities, scopes) in bindings.items():
    payload = {
        "schemaVersion": "operator.actor-binding/v1",
        "bindingId": binding_id,
        "subject": subject,
        "capabilities": sorted(capabilities),
        "leaseScopes": scopes,
    }
    path = root / f"{binding_id}.json"
    path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
PY
}

DEFINITION="$TMP_ROOT/definition.json"
cat > "$DEFINITION" <<'JSON'
{
  "schemaVersion": "operator.control-graph/v1",
  "graphId": "adversarial-smoke",
  "nodes": [
    {"id": "goal", "kind": "goal"},
    {"id": "feature", "kind": "feature"},
    {"id": "lane-a", "kind": "lane"},
    {"id": "lane-b", "kind": "lane"},
    {"id": "dependency", "kind": "task"},
    {"id": "main", "kind": "task", "priority": 20},
    {"id": "validation", "kind": "validation"},
    {"id": "gate", "kind": "human-gate"},
    {"id": "gate-reject", "kind": "human-gate"},
    {"id": "integration", "kind": "integration"},
    {"id": "integration-no-gate", "kind": "integration"},
    {"id": "host-task", "kind": "task"},
    {"id": "side-effect", "kind": "task", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
    {"id": "safe-task", "kind": "task", "metadata": {"execution": {"idempotent": true, "reclaimable": true}}}
  ],
  "edges": [
    {"kind": "contains", "from": "goal", "to": "feature"},
    {"kind": "contains", "from": "feature", "to": "lane-a"},
    {"kind": "contains", "from": "feature", "to": "lane-b"},
    {"kind": "contains", "from": "feature", "to": "dependency"},
    {"kind": "contains", "from": "feature", "to": "main"},
    {"kind": "contains", "from": "feature", "to": "validation"},
    {"kind": "contains", "from": "feature", "to": "gate"},
    {"kind": "contains", "from": "feature", "to": "gate-reject"},
    {"kind": "contains", "from": "feature", "to": "integration"},
    {"kind": "contains", "from": "feature", "to": "integration-no-gate"},
    {"kind": "contains", "from": "feature", "to": "host-task"},
    {"kind": "contains", "from": "feature", "to": "side-effect"},
    {"kind": "contains", "from": "feature", "to": "safe-task"},
    {"kind": "assigned-to", "from": "dependency", "to": "lane-a"},
    {"kind": "assigned-to", "from": "main", "to": "lane-a"},
    {"kind": "assigned-to", "from": "validation", "to": "lane-a"},
    {"kind": "assigned-to", "from": "integration", "to": "lane-a"},
    {"kind": "assigned-to", "from": "integration-no-gate", "to": "lane-a"},
    {"kind": "assigned-to", "from": "host-task", "to": "lane-a"},
    {"kind": "assigned-to", "from": "side-effect", "to": "lane-a"},
    {"kind": "assigned-to", "from": "safe-task", "to": "lane-a"},
    {"kind": "depends-on", "from": "main", "to": "dependency"},
    {"kind": "validated-by", "from": "main", "to": "validation"},
    {"kind": "gated-by", "from": "main", "to": "gate"},
    {"kind": "gated-by", "from": "integration", "to": "gate-reject"},
    {"kind": "integrates-into", "from": "integration", "to": "feature"},
    {"kind": "integrates-into", "from": "integration-no-gate", "to": "feature"}
  ]
}
JSON

# Version, type, reference, endpoint, cycle, number, control, size, and depth hardening.
INVALID_DIR="$TMP_ROOT/invalid-operator"
write_bindings "$INVALID_DIR"
UNKNOWN="$TMP_ROOT/unknown.json"
sed 's/operator.control-graph\/v1/operator.control-graph\/v999/' "$DEFINITION" > "$UNKNOWN"
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$UNKNOWN"

for mutation in bad-reference bad-kind bad-endpoint bad-cycle bad-gate-metadata; do
  python3 - "$DEFINITION" "$TMP_ROOT/$mutation.json" "$mutation" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
kind = sys.argv[3]
if kind == "bad-reference":
    value["edges"][0]["to"] = "missing"
elif kind == "bad-kind":
    value["nodes"][5]["kind"] = "job"
elif kind == "bad-endpoint":
    value["edges"].append({"kind": "assigned-to", "from": "goal", "to": "lane-a"})
elif kind == "bad-cycle":
    value["edges"].append({"kind": "depends-on", "from": "feature", "to": "main"})
    value["edges"].append({"kind": "depends-on", "from": "main", "to": "feature"})
else:
    edge = next(item for item in value["edges"] if item["kind"] == "gated-by")
    edge["metadata"] = {"protectedTransitions": ["not-a-state"]}
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
  expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/$mutation.json"
done

printf '{"schemaVersion":"operator.control-graph/v1","graphId":"nan","nodes":[],"edges":[],"x":NaN}\n' > "$TMP_ROOT/nan.json"
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/nan.json"
printf '{"schemaVersion":"operator.control-graph/v1","graphId":"infinity","nodes":[{"id":"n","kind":"task","metadata":{"value":Infinity}}],"edges":[]}\n' > "$TMP_ROOT/infinity.json"
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/infinity.json"
python3 - "$DEFINITION" "$TMP_ROOT/control.json" "$TMP_ROOT/long.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["nodes"][0]["id"] = "bad\u0001id"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["nodes"][0]["id"] = "x" * 129
json.dump(value, open(sys.argv[3], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/control.json"
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/long.json"
python3 - "$DEFINITION" "$TMP_ROOT/deep.json" "$TMP_ROOT/oversized.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
nested = {}
cursor = nested
for _ in range(80):
    cursor["x"] = {}
    cursor = cursor["x"]
value["nodes"][0]["metadata"] = nested
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle)
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    handle.write(" " * (4 * 1024 * 1024 + 1))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/deep.json"
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$TMP_ROOT/oversized.json"

MAIN_DIR="$TMP_ROOT/main-operator"
write_bindings "$MAIN_DIR"
mkdir -p "$MAIN_DIR/roadmap"
printf 'roadmap-sentinel\n' > "$MAIN_DIR/roadmap/sentinel.txt"
ROADMAP_BEFORE="$(shasum -a 256 "$MAIN_DIR/roadmap/sentinel.txt")"

env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id init-main --actor-binding operator > "$TMP_ROOT/init.json"

python3 - "$MAIN_DIR/graph/bindings/lane-a.json" "$MAIN_DIR/graph/bindings/long-scope.json" <<'PY'
import json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["bindingId"] = "long-scope"
value["leaseScopes"][0]["scope"] = "s" * 513
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.chmod(sys.argv[2], 0o600)
PY
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id long-scope --holder-scope lane:a --request-id long-scope --actor-binding long-scope

# Init and replacement authority are type-bound, not capability-label-bound.
for binding in lane-b host human-overpowered subagent; do
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" init \
    --definition "$DEFINITION" --request-id "init-deny-$binding" --actor-binding "$binding"
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
    "$DEFINITION" --request-id "replace-deny-$binding" --actor-binding "$binding"
done
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id fake-human-label --actor-binding fake-human --actor-type human --actor-id human
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id raw-human-label --actor-type human --actor-id human
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id binding-traversal --actor-binding 'a/../../human'

# assigned-to and explicit holder scopes are mandatory.
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id wrong-lane --holder-scope lane:b --request-id wrong-lane --actor-binding lane-b
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id wrong-host-scope --holder-scope lane:a --request-id wrong-host-scope --actor-binding host
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id host-lease --holder-scope host:a --request-id host-lease --actor-binding host > "$TMP_ROOT/host-lease.json"

ACQUIRE_MAIN="$(env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id main-lease --holder-scope lane:a --ttl-seconds 300 --request-id acquire-main --actor-binding lane-a)"
EVENTS_BEFORE_RETRY="$(wc -l < "$MAIN_DIR/graph/events.jsonl" | tr -d ' ')"
ACQUIRE_RETRY="$(env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id main-lease --holder-scope lane:a --ttl-seconds 300 --request-id acquire-main --actor-binding lane-a)"
[ "$ACQUIRE_MAIN" = "$ACQUIRE_RETRY" ] || fail "exact retry did not return original result"
[ "$EVENTS_BEFORE_RETRY" = "$(wc -l < "$MAIN_DIR/graph/events.jsonl" | tr -d ' ')" ] || fail "exact retry appended"
expect_error 7 REQUEST_CONFLICT env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id main-lease --holder-scope lane:a --ttl-seconds 301 --request-id acquire-main --actor-binding lane-a
expect_error 7 REQUEST_CONFLICT env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire main \
  --lease-id main-lease --holder-scope lane:a --ttl-seconds 300 --request-id acquire-main --actor-binding lane-a-test

# depends-on cannot be bypassed before ready/active.
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main ready \
  --lease-id main-lease --fence 1 --request-id main-ready-early --actor-binding lane-a
for pair in 'pending ready dep-ready' 'ready active dep-active' 'active completed dep-complete'; do
  set -- $pair
  env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition dependency "$2" \
    --request-id "$3" --actor-binding operator > /dev/null
done
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main ready \
  --lease-id main-lease --fence 1 --request-id main-ready --actor-binding lane-a > /dev/null

# Default task gate protects active/completed; a pending gate fails closed.
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main active \
  --lease-id main-lease --fence 1 --request-id main-active-early --actor-binding lane-a
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id gate-approved --actor-binding human > /dev/null
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main active \
  --lease-id main-lease --fence 1 --request-id main-active --actor-binding lane-a > /dev/null

# validated-by cannot be bypassed before completion.
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main completed \
  --lease-id main-lease --fence 1 --request-id main-complete-early --actor-binding lane-a
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire validation \
  --lease-id validation-lease --holder-scope lane:a --request-id validation-lease --actor-binding lane-a > /dev/null
for pair in 'ready validation-ready' 'active validation-active' 'completed validation-complete'; do
  set -- $pair
  env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition validation "$1" \
    --lease-id validation-lease --fence 1 --request-id "$2" --actor-binding lane-a > /dev/null
done
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition main completed \
  --lease-id main-lease --fence 1 --request-id main-complete --actor-binding lane-a > /dev/null

# Integration defaults protect ready/active/completed; missing and rejected gates fail closed.
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire integration-no-gate \
  --lease-id no-gate-lease --holder-scope lane:a --request-id no-gate-lease --actor-binding lane-a > /dev/null
expect_error 21 GATE_REQUIRED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition integration-no-gate ready \
  --lease-id no-gate-lease --fence 1 --request-id integration-missing-gate --actor-binding lane-a
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate-reject rejected \
  --request-id gate-rejected --actor-binding human > /dev/null
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" lease acquire integration \
  --lease-id integration-lease --holder-scope lane:a --request-id integration-lease --actor-binding lane-a > /dev/null
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" transition integration ready \
  --lease-id integration-lease --fence 1 --request-id integration-rejected-gate --actor-binding lane-a

# Status and snapshot expose the same locked deterministic semantic snapshot.
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" status > "$TMP_ROOT/status.json"
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" snapshot > "$TMP_ROOT/snapshot.json"
python3 - "$TMP_ROOT/status.json" "$TMP_ROOT/snapshot.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))
snapshot = json.load(open(sys.argv[2], encoding="utf-8"))
assert status["data"] == snapshot["data"]
data = status["data"]
assert data["revision"] == data["eventCount"]
assert data["definitionRevision"] == 1
assert data["definitionHash"].startswith("sha256:")
assert isinstance(data["nodes"], list) and isinstance(data["edges"], list)
main = next(node for node in data["nodes"] if node["id"] == "main")
assert main["state"] == "completed" and main["metadata"] == {}
gate_edge = next(edge for edge in data["edges"] if edge["kind"] == "gated-by" and edge["from"] == "main")
assert gate_edge["metadata"]["protectedTransitions"] == ["active", "completed"]
assert data["leases"]["main"]["holder"]["bindingId"] == "lane-a"
PY

# Activated/completed identity is immutable; node IDs can never be removed or kind-reused.
python3 - "$MAIN_DIR/graph/definition.json" "$TMP_ROOT/rewrite-history.json" "$TMP_ROOT/remove-node.json" "$TMP_ROOT/rewrite-edge.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for node in value["nodes"]:
    if node["id"] == "main":
        node["title"] = "rewritten completed work"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["nodes"] = [node for node in value["nodes"] if node["id"] != "main"]
value["edges"] = [edge for edge in value["edges"] if edge["from"] != "main" and edge["to"] != "main"]
json.dump(value, open(sys.argv[3], "w", encoding="utf-8"))
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["edges"] = [edge for edge in value["edges"] if not (edge["kind"] == "gated-by" and edge["from"] == "main")]
json.dump(value, open(sys.argv[4], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/rewrite-history.json" --request-id rewrite-history --actor-binding operator
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/remove-node.json" --request-id remove-history --actor-binding operator
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/rewrite-edge.json" --request-id rewrite-edge --actor-binding operator

# Crash safety: partial tail recovery, event roll-forward, and definition/projection gap.
CRASH_DIR="$TMP_ROOT/crash-operator"
write_bindings "$CRASH_DIR"
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id crash-init --actor-binding operator > /dev/null
expect_error 19 TEST_FAULT env OPERATOR_DIR="$CRASH_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition feature active \
  --request-id partial-tail --actor-binding operator --test-only-fault partial-tail
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" transition feature active \
  --request-id partial-tail --actor-binding operator > "$TMP_ROOT/partial-retry.json"
expect_error 19 TEST_FAULT env OPERATOR_DIR="$CRASH_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition feature blocked \
  --request-id after-event --actor-binding operator --test-only-fault after-event
AFTER_EVENT_RETRY="$(env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" transition feature blocked \
  --request-id after-event --actor-binding operator)"
AFTER_EVENT_RETRY_2="$(env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" transition feature blocked \
  --request-id after-event --actor-binding operator)"
[ "$AFTER_EVENT_RETRY" = "$AFTER_EVENT_RETRY_2" ] || fail "event-before-materialization retry changed result"
python3 - "$CRASH_DIR/graph/definition.json" "$TMP_ROOT/crash-replacement.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value.pop("definitionRevision", None)
value["nodes"].append({"id": "forward-node", "kind": "feedback"})
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 19 TEST_FAULT env OPERATOR_DIR="$CRASH_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/crash-replacement.json" --request-id after-definition --actor-binding operator --test-only-fault after-definition
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" replace-definition "$TMP_ROOT/crash-replacement.json" \
  --request-id after-definition --actor-binding operator > /dev/null
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" replay check > /dev/null
python3 - "$CRASH_DIR/graph/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [event["sequence"] for event in events] == list(range(1, len(events) + 1))
assert len({event["requestId"] for event in events}) == len(events)
PY

# Trusted time, unsafe expiry reconciliation, safe reclaim, and fence tombstones.
TIME_DIR="$TMP_ROOT/time-operator"
write_bindings "$TIME_DIR"
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id time-init --actor-binding operator --test-only-now 2026-01-01T00:00:00Z > /dev/null
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id future-theft --holder-scope lane:a --request-id future-theft --actor-binding lane-a --test-only-now 2099-01-01T00:00:00Z
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-1 --holder-scope lane:a --ttl-seconds 1 --request-id side-1 --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:01Z > /dev/null
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition side-effect ready \
  --lease-id side-1 --fence 1 --request-id side-ready --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:01.100000Z > /dev/null
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition side-effect active \
  --lease-id side-1 --fence 1 --request-id side-active --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:01.200000Z > /dev/null
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-2 --holder-scope lane:a --request-id side-2-early --actor-binding lane-a-recovery --test-only-now 2026-01-01T00:00:03Z
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease sweep \
  --request-id side-sweep --actor-binding operator --test-only-now 2026-01-01T00:00:03Z > "$TMP_ROOT/side-sweep.json"
python3 - "$TMP_ROOT/side-sweep.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
item = next(item for item in value["data"]["expired"] if item["nodeId"] == "side-effect")
assert item["fromState"] == "active" and item["toState"] == "blocked" and item["reconciliation"] is True
PY
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-2 --holder-scope lane:a --request-id side-2 --actor-binding lane-a-recovery --test-only-now 2026-01-01T00:00:04Z > "$TMP_ROOT/side-2.json"
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease renew side-effect \
  --lease-id side-1 --fence 1 --request-id side-stale-renew --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:04.100000Z
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease release side-effect \
  --lease-id side-1 --fence 1 --request-id side-stale-release --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:04.100000Z
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition side-effect ready \
  --lease-id side-1 --fence 1 --request-id side-stale-transition --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:04.100000Z
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id safe-1 --holder-scope lane:a --ttl-seconds 1 --request-id safe-1 --actor-binding lane-a-test --test-only-now 2026-01-01T00:00:05Z > /dev/null
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id safe-2 --holder-scope lane:a --request-id safe-2 --actor-binding lane-a-recovery --test-only-now 2026-01-01T00:00:07Z > "$TMP_ROOT/safe-2.json"
python3 - "$TMP_ROOT/side-2.json" "$TMP_ROOT/safe-2.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    value = json.load(open(path, encoding="utf-8"))
    assert value["data"]["lease"]["fence"] == 2, value
PY
env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition feature active \
  --request-id time-forward --actor-binding operator --test-only-now 2026-01-01T00:00:08Z > /dev/null
expect_error 23 CLOCK_ROLLBACK env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition goal active \
  --request-id time-backward --actor-binding operator --test-only-now 2026-01-01T00:00:07.500000Z
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" snapshot > "$TMP_ROOT/time-snapshot.json"
python3 - "$TMP_ROOT/time-snapshot.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
states = {node["id"]: node["state"] for node in value["nodes"]}
assert states["side-effect"] == "blocked"
assert value["leaseFences"]["side-effect"] == 2
assert value["leaseFences"]["safe-task"] == 2
PY

# A real two-process lease race still has exactly one winner.
RACE_DIR="$TMP_ROOT/race-operator"
write_bindings "$RACE_DIR"
env OPERATOR_DIR="$RACE_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id race-init --actor-binding operator > /dev/null
set +e
env OPERATOR_DIR="$RACE_DIR" bash "$GRAPH_SCRIPT" lease acquire safe-task --lease-id race-a \
  --holder-scope lane:a --request-id race-a --actor-binding lane-a > "$TMP_ROOT/race-a.out" 2> "$TMP_ROOT/race-a.err" &
RACE_A_PID="$!"
env OPERATOR_DIR="$RACE_DIR" bash "$GRAPH_SCRIPT" lease acquire safe-task --lease-id race-b \
  --holder-scope lane:a --request-id race-b --actor-binding lane-a > "$TMP_ROOT/race-b.out" 2> "$TMP_ROOT/race-b.err" &
RACE_B_PID="$!"
wait "$RACE_A_PID"; RACE_A_STATUS="$?"
wait "$RACE_B_PID"; RACE_B_STATUS="$?"
set -e
if ! { [ "$RACE_A_STATUS" -eq 0 ] && [ "$RACE_B_STATUS" -eq 9 ]; } && \
   ! { [ "$RACE_A_STATUS" -eq 9 ] && [ "$RACE_B_STATUS" -eq 0 ]; }; then
  cat "$TMP_ROOT/race-a.out" "$TMP_ROOT/race-a.err" "$TMP_ROOT/race-b.out" "$TMP_ROOT/race-b.err" >&2
  fail "lease race did not have exactly one winner"
fi

# Host-aware stale lock rules: foreign live fails closed, foreign expired and PID reuse recover.
PYTHONPATH="$KIT_ROOT/scripts" python3 - "$TMP_ROOT" <<'PY'
import datetime as dt
import os
import sys
from pathlib import Path
import operator_graph as graph

root = Path(sys.argv[1])
def owner(**updates):
    now = graph.utc_now()
    value = {
        "schemaVersion": graph.LOCK_VERSION,
        "hostId": graph.HOST_ID,
        "bootId": graph.BOOT_ID,
        "pid": os.getpid(),
        "processStart": graph.process_start(os.getpid()),
        "token": "crafted",
        "heartbeatAt": graph.format_time(now),
        "expiresAt": graph.format_time(now + dt.timedelta(seconds=60)),
    }
    value.update(updates)
    return value

foreign = root / "foreign-lock" / ".lock"
foreign.mkdir(parents=True)
graph.atomic_write_json(foreign / "owner.json", owner(hostId="foreign-host", bootId="foreign-boot"))
try:
    with graph.DirectoryLock(foreign, timeout=0.08, lease_seconds=1):
        raise AssertionError("foreign live lock was stolen")
except graph.GraphError as error:
    assert error.code == "LOCK_TIMEOUT", error.code
graph.atomic_write_json(foreign / "owner.json", owner(
    hostId="foreign-host", bootId="foreign-boot",
    expiresAt=graph.format_time(graph.utc_now() - dt.timedelta(seconds=1)),
))
with graph.DirectoryLock(foreign, timeout=0.2, lease_seconds=1):
    pass

reused = root / "reused-lock" / ".lock"
reused.mkdir(parents=True)
graph.atomic_write_json(reused / "owner.json", owner(processStart="definitely-not-current"))
with graph.DirectoryLock(reused, timeout=0.2, lease_seconds=1):
    pass
PY

# Every persisted schema version fails closed when unknown.
for mutation in unknown-event unknown-projection unknown-lease; do
  target="$TMP_ROOT/$mutation"
  copy_state "$MAIN_DIR" "$target"
  python3 - "$target/graph/events.jsonl" "$target/graph/projection.json" "$mutation" <<'PY'
import json, sys
events_path, projection_path, mutation = sys.argv[1:]
if mutation == "unknown-event":
    lines = open(events_path, encoding="utf-8").readlines()
    event = json.loads(lines[0])
    event["schemaVersion"] = "operator.control-event/v999"
    lines[0] = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
    open(events_path, "w", encoding="utf-8").writelines(lines)
else:
    projection = json.load(open(projection_path, encoding="utf-8"))
    if mutation == "unknown-projection":
        projection["schemaVersion"] = "operator.control-projection/v999"
    else:
        next(iter(projection["leases"].values()))["schemaVersion"] = "operator.ownership-lease/v999"
    with open(projection_path, "w", encoding="utf-8") as handle:
        json.dump(projection, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
PY
  expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$target" bash "$GRAPH_SCRIPT" replay check
done

# Sequence, middle corruption, and invalid event time/result/lease/number are journal corruption.
for mutation in bad-sequence middle invalid-time invalid-result invalid-lease nan-event; do
  target="$TMP_ROOT/corrupt-$mutation"
  copy_state "$MAIN_DIR" "$target"
  python3 - "$target/graph/events.jsonl" "$mutation" <<'PY'
import json, sys
path, mutation = sys.argv[1:]
lines = open(path, "r", encoding="utf-8").readlines()
if mutation == "middle":
    lines[1] = "{broken-json}\n"
else:
    event = json.loads(lines[1])
    if mutation == "bad-sequence":
        event["sequence"] = 99
    elif mutation == "invalid-time":
        event["occurredAt"] = "not-a-time"
    elif mutation == "invalid-result":
        event["result"]["command"] = "transition"
    elif mutation == "invalid-lease":
        lease_event = next(item for item in map(json.loads, lines) if item["type"] == "lease.acquired")
        lease_event["data"]["lease"]["holder"].pop("bindingId")
        index = next(index for index, item in enumerate(lines) if json.loads(item)["type"] == "lease.acquired")
        lines[index] = json.dumps(lease_event, sort_keys=True, separators=(",", ":")) + "\n"
        open(path, "w", encoding="utf-8").writelines(lines)
        raise SystemExit
    else:
        event["result"]["data"]["poison"] = float("nan")
    lines[1] = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
open(path, "w", encoding="utf-8").writelines(lines)
PY
  expect_error 13 CORRUPT_JOURNAL env OPERATOR_DIR="$target" bash "$GRAPH_SCRIPT" replay check
done

# Explicit same-revision projection drift remains detected and repair is capability-bound.
python3 - "$MAIN_DIR/graph/projection.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["nodeStates"]["feature"] = "active"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
expect_error 12 REPLAY_DRIFT env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replay check
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replay repair \
  --request-id repair-denied --actor-binding lane-a
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replay repair \
  --request-id repair-main --actor-binding operator > /dev/null
env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replay check > /dev/null

ROADMAP_AFTER="$(shasum -a 256 "$MAIN_DIR/roadmap/sentinel.txt")"
[ "$ROADMAP_BEFORE" = "$ROADMAP_AFTER" ] || fail "graph commands mutated roadmap state"
[ "$(find "$MAIN_DIR/roadmap" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "graph commands added roadmap files"

printf 'operator v5 control graph adversarial smoke ok: %s\n' "$MAIN_DIR"
