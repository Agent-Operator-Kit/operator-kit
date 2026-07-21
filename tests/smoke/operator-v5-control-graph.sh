#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH_SCRIPT="$KIT_ROOT/scripts/operator-graph.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-control-graph.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

json_field() {
  python3 -c 'import json,sys; value=json.load(sys.stdin); print(value'"$1"')'
}

expect_error() {
  local expected_status="$1"
  local expected_code="$2"
  shift 2
  local output="$TMP_ROOT/error-out.json"
  local error="$TMP_ROOT/error.json"
  local status
  set +e
  "$@" >"$output" 2>"$error"
  status="$?"
  set -e
  [ "$status" -eq "$expected_status" ] || {
    cat "$output" >&2
    cat "$error" >&2
    fail "Expected exit $expected_status, got $status: $*"
  }
  python3 - "$error" "$expected_code" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
assert value["ok"] is False, value
assert value["error"]["code"] == sys.argv[2], value
PY
}

GRAPH_DIR="$TMP_ROOT/operator"
mkdir -p "$GRAPH_DIR/roadmap"
printf '%s\n' 'roadmap-must-not-change' > "$GRAPH_DIR/roadmap/sentinel.txt"
ROADMAP_BEFORE="$(shasum -a 256 "$GRAPH_DIR/roadmap/sentinel.txt")"

DEFINITION="$TMP_ROOT/definition.json"
cat > "$DEFINITION" <<'JSON'
{
  "schemaVersion": "operator.control-graph/v1",
  "graphId": "smoke-graph",
  "nodes": [
    {"id": "goal", "kind": "goal", "title": "Ship V5"},
    {"id": "feature", "kind": "feature"},
    {"id": "lane", "kind": "lane"},
    {"id": "task", "kind": "task", "priority": 20},
    {"id": "validation", "kind": "validation"},
    {"id": "gate", "kind": "human-gate"},
    {"id": "integration", "kind": "integration"},
    {"id": "feedback", "kind": "feedback"}
  ],
  "edges": [
    {"kind": "contains", "from": "goal", "to": "feature"},
    {"kind": "contains", "from": "feature", "to": "lane"},
    {"kind": "contains", "from": "feature", "to": "task"},
    {"kind": "contains", "from": "feature", "to": "validation"},
    {"kind": "contains", "from": "feature", "to": "gate"},
    {"kind": "contains", "from": "feature", "to": "integration"},
    {"kind": "contains", "from": "feature", "to": "feedback"},
    {"kind": "assigned-to", "from": "task", "to": "lane"},
    {"kind": "validated-by", "from": "task", "to": "validation"},
    {"kind": "gated-by", "from": "integration", "to": "gate"},
    {"kind": "integrates-into", "from": "integration", "to": "feature"},
    {"kind": "feedback-for", "from": "feedback", "to": "task"}
  ]
}
JSON

UNKNOWN="$TMP_ROOT/unknown.json"
sed 's/operator.control-graph\/v1/operator.control-graph\/v999/' "$DEFINITION" > "$UNKNOWN"
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate "$UNKNOWN"

BAD_REFERENCE="$TMP_ROOT/bad-reference.json"
python3 - "$DEFINITION" "$BAD_REFERENCE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["edges"][0]["to"] = "missing"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate "$BAD_REFERENCE"

BAD_KIND="$TMP_ROOT/bad-kind.json"
python3 - "$DEFINITION" "$BAD_KIND" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["nodes"][3]["kind"] = "job"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate "$BAD_KIND"

BAD_ENDPOINT="$TMP_ROOT/bad-endpoint.json"
python3 - "$DEFINITION" "$BAD_ENDPOINT" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["edges"].append({"kind": "assigned-to", "from": "goal", "to": "lane"})
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate "$BAD_ENDPOINT"

BAD_CYCLE="$TMP_ROOT/bad-cycle.json"
python3 - "$DEFINITION" "$BAD_CYCLE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["edges"].append({"kind": "depends-on", "from": "feature", "to": "task"})
value["edges"].append({"kind": "depends-on", "from": "task", "to": "feature"})
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate "$BAD_CYCLE"

env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" --request-id init-smoke > "$TMP_ROOT/init.json"
python3 - "$TMP_ROOT/init.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["revision"] == 1 and value["data"]["initialized"] is True, value
PY

STATE_BEFORE="$(shasum -a 256 "$GRAPH_DIR/graph/definition.json" "$GRAPH_DIR/graph/projection.json" "$GRAPH_DIR/graph/events.jsonl")"
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" init --definition "$UNKNOWN" --request-id init-again > "$TMP_ROOT/init-again.json"
STATE_AFTER="$(shasum -a 256 "$GRAPH_DIR/graph/definition.json" "$GRAPH_DIR/graph/projection.json" "$GRAPH_DIR/graph/events.jsonl")"
[ "$STATE_BEFORE" = "$STATE_AFTER" ] || fail "Idempotent init changed existing graph state."

expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id gate-operator --actor-type operator --actor-id control
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id gate-human --actor-type human --actor-id norbert > "$TMP_ROOT/gate.json"

expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire task \
  --request-id subagent-lease --actor-type subagent --actor-id child
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition integration ready \
  --request-id subagent-integrate --actor-type subagent --actor-id child

PRIORITY_DEFINITION="$TMP_ROOT/priority-definition.json"
python3 - "$DEFINITION" "$PRIORITY_DEFINITION" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["nodes"][3]["priority"] = 99
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" replace-definition "$PRIORITY_DEFINITION" \
  --request-id subagent-priority --actor-type subagent --actor-id child

env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire task --lease-id old-task-lease \
  --holder-scope lane:control-graph --ttl-seconds 1 --request-id acquire-old \
  --actor-type lane --actor-id control-graph --now 2026-01-01T00:00:00Z > "$TMP_ROOT/acquire-old.json"
OLD_FENCE="$(json_field '["data"]["lease"]["fence"]' < "$TMP_ROOT/acquire-old.json")"
[ "$OLD_FENCE" -eq 1 ] || fail "First fence was not 1."

FIRST_TRANSITION="$(env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition task ready \
  --lease-id old-task-lease --fence "$OLD_FENCE" --request-id task-ready \
  --actor-type lane --actor-id control-graph --now 2026-01-01T00:00:00.500000Z)"
EVENTS_BEFORE_DUPLICATE="$(wc -l < "$GRAPH_DIR/graph/events.jsonl" | tr -d ' ')"
DUPLICATE_TRANSITION="$(env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition task ready \
  --lease-id old-task-lease --fence "$OLD_FENCE" --request-id task-ready \
  --expected-revision 1 --actor-type subagent --actor-id different --now 2030-01-01T00:00:00Z)"
EVENTS_AFTER_DUPLICATE="$(wc -l < "$GRAPH_DIR/graph/events.jsonl" | tr -d ' ')"
[ "$FIRST_TRANSITION" = "$DUPLICATE_TRANSITION" ] || fail "Duplicate request did not return the original result."
[ "$EVENTS_BEFORE_DUPLICATE" = "$EVENTS_AFTER_DUPLICATE" ] || fail "Duplicate request appended an event."

env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire task --lease-id new-task-lease \
  --holder-scope lane:recovery --ttl-seconds 60 --request-id acquire-new \
  --actor-type lane --actor-id recovery --now 2026-01-01T00:00:02Z > "$TMP_ROOT/acquire-new.json"
NEW_FENCE="$(json_field '["data"]["lease"]["fence"]' < "$TMP_ROOT/acquire-new.json")"
[ "$NEW_FENCE" -eq 2 ] || fail "Reclaim did not increment the fence."

expect_error 10 FENCE_STALE env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease renew task \
  --lease-id old-task-lease --fence "$OLD_FENCE" --request-id stale-renew \
  --actor-type lane --actor-id control-graph --now 2026-01-01T00:00:03Z
expect_error 10 FENCE_STALE env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease release task \
  --lease-id old-task-lease --fence "$OLD_FENCE" --request-id stale-release \
  --actor-type lane --actor-id control-graph --now 2026-01-01T00:00:03Z
expect_error 10 FENCE_STALE env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition task active \
  --lease-id old-task-lease --fence "$OLD_FENCE" --request-id stale-transition \
  --actor-type lane --actor-id control-graph --now 2026-01-01T00:00:03Z
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition task active \
  --lease-id new-task-lease --fence "$NEW_FENCE" --request-id current-transition \
  --actor-type lane --actor-id recovery --now 2026-01-01T00:00:03Z > "$TMP_ROOT/current-transition.json"

expect_error 6 REVISION_CONFLICT env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" transition feature active \
  --request-id bad-cas --expected-revision 1 --actor-type operator --actor-id control

# A real two-process acquire race must produce exactly one successful append.
set +e
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire validation --lease-id race-a \
  --request-id race-a --actor-type lane --actor-id race-a > "$TMP_ROOT/race-a.out" 2> "$TMP_ROOT/race-a.err" &
RACE_A_PID="$!"
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire validation --lease-id race-b \
  --request-id race-b --actor-type lane --actor-id race-b > "$TMP_ROOT/race-b.out" 2> "$TMP_ROOT/race-b.err" &
RACE_B_PID="$!"
wait "$RACE_A_PID"
RACE_A_STATUS="$?"
wait "$RACE_B_PID"
RACE_B_STATUS="$?"
set -e
if [ "$RACE_A_STATUS" -eq 0 ] && [ "$RACE_B_STATUS" -eq 9 ]; then
  RACE_LOSER="$TMP_ROOT/race-b.err"
elif [ "$RACE_A_STATUS" -eq 9 ] && [ "$RACE_B_STATUS" -eq 0 ]; then
  RACE_LOSER="$TMP_ROOT/race-a.err"
else
  cat "$TMP_ROOT/race-a.out" "$TMP_ROOT/race-a.err" "$TMP_ROOT/race-b.out" "$TMP_ROOT/race-b.err" >&2
  fail "Two-process lease race did not have exactly one winner."
fi
python3 - "$RACE_LOSER" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["error"]["code"] == "LEASE_CONFLICT", value
PY

env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease acquire feedback --lease-id expires \
  --ttl-seconds 1 --request-id acquire-expiry --actor-type lane --actor-id expiry \
  --now 2026-01-01T00:00:00Z > "$TMP_ROOT/acquire-expiry.json"
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" lease sweep --request-id sweep-expiry \
  --actor-type system --actor-id heartbeat --now 2026-01-01T00:00:02Z > "$TMP_ROOT/sweep.json"
python3 - "$TMP_ROOT/sweep.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["data"]["count"] == 1, value
assert value["data"]["expired"][0]["nodeId"] == "feedback", value
PY

python3 - "$GRAPH_DIR/graph/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [event["sequence"] for event in events] == list(range(1, len(events) + 1)), events
assert len({event["requestId"] for event in events}) == len(events), events
PY

UNKNOWN_EVENT_DIR="$TMP_ROOT/unknown-event-operator"
mkdir -p "$UNKNOWN_EVENT_DIR/graph"
cp "$GRAPH_DIR/graph/definition.json" "$UNKNOWN_EVENT_DIR/graph/definition.json"
cp "$GRAPH_DIR/graph/projection.json" "$UNKNOWN_EVENT_DIR/graph/projection.json"
cp "$GRAPH_DIR/graph/events.jsonl" "$UNKNOWN_EVENT_DIR/graph/events.jsonl"
python3 - "$UNKNOWN_EVENT_DIR/graph/events.jsonl" <<'PY'
import json, sys
path = sys.argv[1]
events = [json.loads(line) for line in open(path, encoding="utf-8")]
events[0]["schemaVersion"] = "operator.control-event/v999"
with open(path, "w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$UNKNOWN_EVENT_DIR" bash "$GRAPH_SCRIPT" replay check

UNKNOWN_PROJECTION_DIR="$TMP_ROOT/unknown-projection-operator"
mkdir -p "$UNKNOWN_PROJECTION_DIR/graph"
cp "$GRAPH_DIR/graph/definition.json" "$UNKNOWN_PROJECTION_DIR/graph/definition.json"
cp "$GRAPH_DIR/graph/projection.json" "$UNKNOWN_PROJECTION_DIR/graph/projection.json"
cp "$GRAPH_DIR/graph/events.jsonl" "$UNKNOWN_PROJECTION_DIR/graph/events.jsonl"
python3 - "$UNKNOWN_PROJECTION_DIR/graph/projection.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["schemaVersion"] = "operator.control-projection/v999"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$UNKNOWN_PROJECTION_DIR" bash "$GRAPH_SCRIPT" replay check

UNKNOWN_LEASE_DIR="$TMP_ROOT/unknown-lease-operator"
mkdir -p "$UNKNOWN_LEASE_DIR/graph"
cp "$GRAPH_DIR/graph/definition.json" "$UNKNOWN_LEASE_DIR/graph/definition.json"
cp "$GRAPH_DIR/graph/projection.json" "$UNKNOWN_LEASE_DIR/graph/projection.json"
cp "$GRAPH_DIR/graph/events.jsonl" "$UNKNOWN_LEASE_DIR/graph/events.jsonl"
python3 - "$UNKNOWN_LEASE_DIR/graph/projection.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
next(iter(value["leases"].values()))["schemaVersion"] = "operator.ownership-lease/v999"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$UNKNOWN_LEASE_DIR" bash "$GRAPH_SCRIPT" replay check

CORRUPT_DIR="$TMP_ROOT/corrupt-operator"
mkdir -p "$CORRUPT_DIR/graph"
cp "$GRAPH_DIR/graph/definition.json" "$CORRUPT_DIR/graph/definition.json"
cp "$GRAPH_DIR/graph/projection.json" "$CORRUPT_DIR/graph/projection.json"
cp "$GRAPH_DIR/graph/events.jsonl" "$CORRUPT_DIR/graph/events.jsonl"
python3 - "$CORRUPT_DIR/graph/events.jsonl" <<'PY'
import json, sys
path = sys.argv[1]
events = [json.loads(line) for line in open(path, encoding="utf-8")]
events[1]["sequence"] = 99
with open(path, "w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
expect_error 13 CORRUPT_JOURNAL env OPERATOR_DIR="$CORRUPT_DIR" bash "$GRAPH_SCRIPT" replay check

# Valid journal plus a semantically valid but altered projection is replay drift.
python3 - "$GRAPH_DIR/graph/projection.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["nodeStates"]["feature"] = "active"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
expect_error 12 REPLAY_DRIFT env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" replay check
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" replay repair --request-id repair-drift \
  --actor-type operator --actor-id control > "$TMP_ROOT/repair.json"
env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" replay check > "$TMP_ROOT/replay-check.json"
python3 - "$TMP_ROOT/replay-check.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["data"]["inSync"] is True, value
PY

env OPERATOR_DIR="$GRAPH_DIR" bash "$GRAPH_SCRIPT" validate > "$TMP_ROOT/validate.json"
ROADMAP_AFTER="$(shasum -a 256 "$GRAPH_DIR/roadmap/sentinel.txt")"
[ "$ROADMAP_BEFORE" = "$ROADMAP_AFTER" ] || fail "Graph commands mutated roadmap state."
[ "$(find "$GRAPH_DIR/roadmap" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "Graph commands added roadmap files."

printf 'operator v5 control graph smoke ok: %s\n' "$GRAPH_DIR"
