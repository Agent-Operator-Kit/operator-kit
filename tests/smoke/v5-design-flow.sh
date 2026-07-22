#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG PROJECT_NAME PROJECT_ROOT CODE_DIR TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESIGN_FLOW="$KIT_ROOT/scripts/operator-design-flow.sh"
SCHEDULER="$KIT_ROOT/scripts/operator-scheduler.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-design-flow.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export OPERATOR_DIR="$TMP_ROOT/operator"
FEATURE_DIR="$OPERATOR_DIR/features/FS-0008-rm-0006-design-flow"
FEATURE_TWO_DIR="$OPERATOR_DIR/features/FS-0009-rm-0006-design-flow-two"
SNAPSHOT="$TMP_ROOT/snapshot.json"
GRAPH_LOG="$TMP_ROOT/graph-requests.jsonl"
FEEDBACK_LOG="$TMP_ROOT/feedback-requests.jsonl"
mkdir -p "$FEATURE_DIR" "$FEATURE_TWO_DIR" "$OPERATOR_DIR/graph"
printf 'control-owned marker\n' > "$OPERATOR_DIR/graph/DO-NOT-READ"
printf '{"id":"FS-0008","slug":"rm-0006-design-flow"}\n' > "$FEATURE_DIR/status.json"
printf '{"id":"FS-0009","slug":"rm-0006-design-flow-two"}\n' > "$FEATURE_TWO_DIR/status.json"
printf '# Shared design brief\n\nCreate a focused first-value experience.\n' > "$TMP_ROOT/brief.md"

python3 - "$SNAPSHOT" <<'PY'
import json, sys
path = sys.argv[1]
nodes = [
    {"id":"goal","kind":"goal","title":"Goal","initialState":"planned","priority":0,"metadata":{},"state":"active"},
    {"id":"FS-0008","kind":"feature","title":"Design flow","initialState":"planned","priority":0,
     "metadata":{"featureSessionId":"FS-0008"},"state":"active"},
    {"id":"FS-0009","kind":"feature","title":"Design flow two","initialState":"planned","priority":0,
     "metadata":{"featureSessionId":"FS-0009"},"state":"active"},
    {"id":"design-lane","kind":"lane","title":"Design lane","initialState":"planned","priority":0,"metadata":{},"state":"active"},
    {"id":"other-lane","kind":"lane","title":"Other lane","initialState":"planned","priority":0,"metadata":{},"state":"active"},
]
edges = [
    {"id":"contains:goal:FS-0008","kind":"contains","from":"goal","to":"FS-0008","metadata":{}},
    {"id":"contains:FS-0008:design-lane","kind":"contains","from":"FS-0008","to":"design-lane","metadata":{}},
    {"id":"contains:goal:FS-0009","kind":"contains","from":"goal","to":"FS-0009","metadata":{}},
    {"id":"contains:FS-0009:other-lane","kind":"contains","from":"FS-0009","to":"other-lane","metadata":{}},
]
value = {
    "schemaVersion":"operator.control-snapshot/v1","graphId":"design-smoke","revision":1,
    "definitionRevision":1,"definitionHash":"sha256:" + "0" * 64,
    "updatedAt":"2026-07-22T00:00:00.000000Z","eventCount":1,
    "nodes":nodes,"edges":edges,"leases":{},"leaseFences":{},"executionStarted":{},
    "reconciliations":{},"bindingGenerations":{},"authorityKeyId":"smoke-key",
    "authorityHash":"sha256:" + "1" * 64,
}
path = __import__('pathlib').Path(path)
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

cat > "$TMP_ROOT/snapshot-provider" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${DESIGN_SMOKE_SNAPSHOT_READY:-}" ]; then
  : > "$DESIGN_SMOKE_SNAPSHOT_READY"
  while [ ! -e "${DESIGN_SMOKE_SNAPSHOT_GO:?}" ]; do sleep 0.01; done
fi
exec /bin/cat "$DESIGN_SMOKE_SNAPSHOT"
SH
chmod +x "$TMP_ROOT/snapshot-provider"

cat > "$TMP_ROOT/graph-launcher" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys

def reject_float(raw):
    raise ValueError(raw)

def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise ValueError("duplicate key")
        value[key] = item
    return value

request = json.loads(sys.stdin.read(), parse_float=reject_float, parse_constant=reject_float,
                     object_pairs_hook=pairs)
required = {"schemaVersion","command","requestId","graphId","expectedRevision","definition","gateNodeId","decision"}
assert set(request) == required
assert request["schemaVersion"] == "operator.design-flow-graph-mutation-request/v1"
assert "actorBinding" not in request and "proofFd" not in request and "authorityKey" not in request

snapshot_path = pathlib.Path(os.environ["DESIGN_SMOKE_SNAPSHOT"])
log_path = pathlib.Path(os.environ["DESIGN_SMOKE_GRAPH_LOG"])
snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
if request["graphId"] != snapshot["graphId"] or request["expectedRevision"] != snapshot["revision"]:
    print('{"error":{"code":"REVISION_CONFLICT","message":"stale"},"ok":false}', file=sys.stderr)
    raise SystemExit(9)

command = request["command"]
if command == "replace-definition":
    assert request["gateNodeId"] is None and request["decision"] is None
    definition = request["definition"]
    assert set(definition) == {"schemaVersion","graphId","nodes","edges"}
    prior_states = {item["id"]: item["state"] for item in snapshot["nodes"]}
    nodes = []
    for item in definition["nodes"]:
        normalized = dict(item)
        normalized["state"] = prior_states.get(item["id"], item["initialState"])
        nodes.append(normalized)
    snapshot["nodes"] = sorted(nodes, key=lambda item: item["id"])
    snapshot["edges"] = sorted(definition["edges"], key=lambda item: item["id"])
    snapshot["revision"] += 1
    snapshot["definitionRevision"] += 1
    snapshot["eventCount"] += 1
    snapshot["definitionHash"] = "sha256:" + format(snapshot["definitionRevision"], "064x")
    data = {"graphId":snapshot["graphId"],"definitionRevision":snapshot["definitionRevision"],
            "nodes":len(snapshot["nodes"]),"edges":len(snapshot["edges"])}
    public_command = "replace-definition"
elif command == "gate decide":
    assert request["definition"] is None and request["decision"] in {"approved","rejected"}
    fail_once = os.environ.get("DESIGN_SMOKE_FAIL_GATE_ONCE")
    if fail_once and pathlib.Path(fail_once).exists():
        pathlib.Path(fail_once).unlink()
        print('{"error":{"code":"BROKER_UNAVAILABLE","message":"injected"},"ok":false}', file=sys.stderr)
        raise SystemExit(7)
    gate = next(item for item in snapshot["nodes"] if item["id"] == request["gateNodeId"])
    assert gate["kind"] == "human-gate" and gate["state"] == "pending"
    gate["state"] = request["decision"]
    snapshot["revision"] += 1
    snapshot["eventCount"] += 1
    data = {"nodeId":gate["id"],"from":"pending","to":request["decision"]}
    public_command = "gate decide"
else:
    raise AssertionError(command)

snapshot["updatedAt"] = f"2026-07-22T00:00:{snapshot['revision']:02d}.000000Z"
snapshot_path.write_text(json.dumps(snapshot, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n")
result = {"ok":True,"command":public_command,"requestId":request["requestId"],
          "revision":snapshot["revision"],"data":data}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
chmod +x "$TMP_ROOT/graph-launcher"

cat > "$TMP_ROOT/feedback-owner" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
request = json.load(sys.stdin)
required = {"schemaVersion","requestId","featureId","flowId","improvementNodeId","sourceNodeId",
            "message","messageHash","evidencePath","evidence"}
assert set(request) == required
assert request["schemaVersion"] == "operator.design-flow-feedback-request/v1"
assert request["evidencePath"].startswith("work/design-options/improvements/")
log = pathlib.Path(os.environ["DESIGN_SMOKE_FEEDBACK_LOG"])
existing = [] if not log.exists() else [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line]
match = next((item for item in existing if item["requestId"] == request["requestId"]), None)
if match is None:
    existing.append(request)
    log.write_text("".join(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n" for item in existing), encoding="utf-8")
    number = len(existing)
else:
    number = existing.index(match) + 1
result = {"ok":True,"schemaVersion":"operator.design-flow-feedback-result/v1",
          "requestId":request["requestId"],"feedbackId":f"FB-{number:04d}",
          "status":"inbox","evidencePath":request["evidencePath"]}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
chmod +x "$TMP_ROOT/feedback-owner"

export DESIGN_SMOKE_SNAPSHOT="$SNAPSHOT"
export DESIGN_SMOKE_GRAPH_LOG="$GRAPH_LOG"
export DESIGN_SMOKE_FEEDBACK_LOG="$FEEDBACK_LOG"
export OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND="$TMP_ROOT/snapshot-provider"
export OPERATOR_DESIGN_FLOW_MUTATION_COMMAND="$TMP_ROOT/graph-launcher"
export OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND="$TMP_ROOT/feedback-owner"

expect_error() {
  local expected="$1"
  shift
  local error_file="$TMP_ROOT/error.json"
  if "$@" > /dev/null 2> "$error_file"; then
    printf 'expected command to fail with %s\n' "$expected" >&2
    exit 1
  fi
  python3 - "$error_file" "$expected" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["ok"] is False and value["error"]["code"] == sys.argv[2], value
PY
}

snapshot_case() {
  local variant="$1"
  local expected="$2"
  local backup="$TMP_ROOT/snapshot-case-backup.json"
  cp "$SNAPSHOT" "$backup"
  python3 - "$SNAPSHOT" "$variant" <<'PY'
import copy, json, pathlib, sys
path, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
value = json.loads(path.read_text(encoding="utf-8"))

def design(role=None, proposal=None):
    items = []
    for node in value["nodes"]:
        metadata = node.get("metadata", {}).get("designFlow", {})
        if metadata.get("featureId") != "FS-0008" or metadata.get("flowId") != "design":
            continue
        if role is not None and metadata.get("role") != role:
            continue
        if proposal is not None and metadata.get("proposal") != proposal:
            continue
        items.append(node)
    return items

proposal_a = design("proposal", "proposal-a")[0]
proposal_b = design("proposal", "proposal-b")[0]
gate = design("selection-gate")[0]
if variant == "wrong-title":
    proposal_a["title"] = "Impostor title"
elif variant == "wrong-priority":
    proposal_a["priority"] += 1
elif variant == "wrong-artifact":
    proposal_a["metadata"]["designFlow"]["artifactPath"] = "work/design-options/proposal-z"
elif variant == "missing-contains":
    value["edges"] = [edge for edge in value["edges"] if not (edge["kind"] == "contains" and edge["to"] == proposal_a["id"])]
elif variant == "missing-assigned":
    value["edges"] = [edge for edge in value["edges"] if not (edge["kind"] == "assigned-to" and edge["from"] == proposal_a["id"])]
elif variant == "extra-conflicting-edge":
    value["edges"].append({"id":f"depends-on:{proposal_a['id']}:{proposal_b['id']}","kind":"depends-on",
                           "from":proposal_a["id"],"to":proposal_b["id"],"metadata":{}})
elif variant == "unexpected-validated-by":
    validator_id = "unexpected-flow-validator"
    value["nodes"].append({"id":validator_id,"kind":"validation","title":"Unexpected validator",
                           "initialState":"pending","priority":0,"metadata":{},"state":"pending"})
    value["edges"].append({"id":f"validated-by:{proposal_a['id']}:{validator_id}","kind":"validated-by",
                           "from":proposal_a["id"],"to":validator_id,"metadata":{}})
elif variant == "metadata-impostor-implementation":
    node = copy.deepcopy(proposal_a)
    node["id"] = "metadata-impostor-implementation"
    node["title"] = "Impostor implementation"
    node["metadata"]["designFlow"]["role"] = "implementation"
    node["metadata"]["designFlow"].pop("proposal", None)
    value["nodes"].append(node)
elif variant == "invalid-node-kind":
    proposal_a["kind"] = "unknown-work"
elif variant == "invalid-node-state":
    proposal_a["state"] = "approved"
elif variant == "invalid-initial-state":
    proposal_a["initialState"] = "planned"
elif variant == "invalid-edge-kind":
    next(edge for edge in value["edges"] if edge["to"] == proposal_a["id"])["kind"] = "unknown-edge"
elif variant == "invalid-edge-id":
    next(edge for edge in value["edges"] if edge["to"] == proposal_a["id"])["id"] = "invalid edge id"
elif variant == "duplicate-edge-id":
    flow_edges = [edge for edge in value["edges"] if edge["to"] in {proposal_a["id"], proposal_b["id"]}]
    flow_edges[1]["id"] = flow_edges[0]["id"]
elif variant == "missing-edge-endpoint":
    next(edge for edge in value["edges"] if edge["to"] == proposal_a["id"])["to"] = "missing-node"
elif variant == "invalid-hash":
    value["definitionHash"] = "not-a-hash"
elif variant == "invalid-counter":
    value["eventCount"] += 1
elif variant == "invalid-authority-id":
    value["authorityKeyId"] = "invalid authority id"
elif variant == "invalid-gate-state":
    gate["state"] = "mystery"
elif variant == "nodes-over-bound":
    template = {"kind":"lane","title":"Bound node","initialState":"planned","priority":0,"metadata":{},"state":"planned"}
    value["nodes"] = [{"id":f"bound-{index}", **template} for index in range(10001)]
    value["edges"] = []
else:
    raise AssertionError(variant)
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  expect_error "$expected" bash "$DESIGN_FLOW" status --feature FS-0008 --json
  mv "$backup" "$SNAPSHOT"
}

bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json > "$TMP_ROOT/start.json"

python3 - "$TMP_ROOT/start.json" "$SNAPSHOT" "$FEATURE_DIR" <<'PY'
import json, pathlib, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
snapshot = json.load(open(sys.argv[2], encoding="utf-8"))
feature = pathlib.Path(sys.argv[3])
assert status["schemaVersion"] == "operator.design-flow-status/v1"
assert [item["proposal"] for item in status["proposals"]] == ["proposal-a","proposal-b","proposal-c"]
proposal_nodes = [item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "proposal"]
assert len(proposal_nodes) == 3
assert {item["metadata"]["designFlow"]["proposal"] for item in proposal_nodes} == {"proposal-a","proposal-b","proposal-c"}
assert all(item["state"] == "pending" for item in proposal_nodes)
contains = {(edge["from"], edge["to"]) for edge in snapshot["edges"] if edge["kind"] == "contains"}
assert all(("FS-0008", item["id"]) in contains for item in proposal_nodes)
options = feature / "work" / "design-options"
assert sorted(item.name for item in options.iterdir() if item.is_dir()) == ["proposal-a","proposal-b","proposal-c"]
for proposal in ("proposal-a","proposal-b","proposal-c"):
    assert (options / proposal / "prompt.md").is_file()
    assert (options / proposal / "brief.md").is_file()
PY

# Start retries discover the durable graph shape and do not append again.
bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json > /dev/null
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"

# Every start retry field is immutable intent, not a hint.
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane other-lane --title "First value" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "Changed title" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --priority 501 --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" start --feature FS-0008 --feature-node FS-0009 \
  --brief "$TMP_ROOT/brief.md" --lane design-lane --title "First value" --json
printf '# Different brief\n' > "$TMP_ROOT/different-brief.md"
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/different-brief.md" \
  --lane design-lane --title "First value" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" status --feature FS-0008 --feature-node FS-0009 --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"

# Canonical topology rejects immutable drift, missing relations, extra
# relations, and metadata-only impostors before any gate mutation.
for variant in wrong-title wrong-priority wrong-artifact missing-contains missing-assigned extra-conflicting-edge \
  unexpected-validated-by; do
  snapshot_case "$variant" FLOW_CORRUPT
done
cp "$SNAPSHOT" "$TMP_ROOT/impostor-backup.json"
python3 - "$SNAPSHOT" <<'PY'
import copy, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
proposal = next(node for node in value["nodes"] if node.get("metadata",{}).get("designFlow",{}).get("proposal") == "proposal-a")
node = copy.deepcopy(proposal)
node["id"] = "metadata-impostor-implementation"
node["title"] = "Impostor implementation"
node["metadata"]["designFlow"]["role"] = "implementation"
node["metadata"]["designFlow"].pop("proposal", None)
value["nodes"].append(node)
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_error FLOW_CORRUPT bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"
mv "$TMP_ROOT/impostor-backup.json" "$SNAPSHOT"

# The snapshot provider must stay inside the exact RM-0007 public domain.
for variant in invalid-node-kind invalid-node-state invalid-initial-state invalid-edge-kind invalid-edge-id \
  duplicate-edge-id missing-edge-endpoint invalid-hash invalid-counter invalid-authority-id invalid-gate-state \
  nodes-over-bound; do
  snapshot_case "$variant" INTERFACE_PROTOCOL
done

expect_error PROPOSALS_INCOMPLETE bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --json

printf '# Proposal A result\n' > "$FEATURE_DIR/work/design-options/proposal-a/README.md"
python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
for node in value["nodes"]:
    if node.get("metadata",{}).get("designFlow",{}).get("role") == "proposal":
        node["state"] = "completed"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

# Rejection is durable but is never reported as approval or selection.
cp "$SNAPSHOT" "$TMP_ROOT/rejected-backup.json"
python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
gate = next(node for node in value["nodes"] if node.get("metadata",{}).get("designFlow",{}).get("role") == "selection-gate"
            and node["metadata"]["designFlow"].get("featureId") == "FS-0008")
gate["state"] = "rejected"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
bash "$DESIGN_FLOW" status --feature FS-0008 --json > "$TMP_ROOT/rejected-status.json"
python3 - "$TMP_ROOT/rejected-status.json" <<'PY'
import json, sys
selection = json.load(open(sys.argv[1], encoding="utf-8"))["data"]["selection"]
assert selection["gateState"] == "rejected"
assert selection["durableGraphGate"] is True
assert selection["approved"] is False
assert selection["selectedProposal"] is None
assert selection["proposedProposal"] is None
PY
mv "$TMP_ROOT/rejected-backup.json" "$SNAPSHOT"

# Inject a host failure after the implementation definition append. The child
# remains gated and the same select retry must finish only the graph gate event.
touch "$TMP_ROOT/fail-gate-once"
export DESIGN_SMOKE_FAIL_GATE_ONCE="$TMP_ROOT/fail-gate-once"
expect_error TRUSTED_INTERFACE_FAILED bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --json

python3 - "$SNAPSHOT" "$TMP_ROOT/clock.json" <<'PY'
import json, pathlib, sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
gate = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "selection-gate")
implementation = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
assert gate["state"] == "pending" and implementation["state"] == "pending"
assert implementation["metadata"]["designFlow"]["selectedProposal"] == "proposal-b"
clock = {"schemaVersion":"operator.scheduler-clock/v1","hostId":"smoke-host","bootId":"smoke-boot",
         "monotonicSource":"macos-mach-continuous","monotonicNs":1000000000}
pathlib.Path(sys.argv[2]).write_text(json.dumps(clock, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

# A canonical-looking implementation without its exact gated-by relationship
# is corrupt and must not trigger the human gate mutation on retry.
cp "$SNAPSHOT" "$TMP_ROOT/missing-gate-backup.json"
python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
implementation = next(node for node in value["nodes"] if node.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
value["edges"] = [edge for edge in value["edges"] if not (edge["kind"] == "gated-by" and edge["from"] == implementation["id"])]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_error FLOW_CORRUPT bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "2"
mv "$TMP_ROOT/missing-gate-backup.json" "$SNAPSHOT"

bash "$SCHEDULER" frontier --snapshot "$SNAPSHOT" --clock "$TMP_ROOT/clock.json" \
  --capacity 10 --json --explain > "$TMP_ROOT/frontier-pending.json"
python3 - "$TMP_ROOT/frontier-pending.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
item = next(item for item in data["excluded"] if "implementation" in item["nodeId"])
assert [reason["code"] for reason in item["reasons"]] == ["GATE_PENDING"]
PY

bash "$DESIGN_FLOW" select --feature FS-0008 --lane design-lane \
  --proposal proposal-b --json > "$TMP_ROOT/selected.json"
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "3"

bash "$SCHEDULER" frontier --snapshot "$SNAPSHOT" --clock "$TMP_ROOT/clock.json" \
  --capacity 10 --json --explain > "$TMP_ROOT/frontier-approved.json"
python3 - "$TMP_ROOT/selected.json" "$TMP_ROOT/frontier-approved.json" "$SNAPSHOT" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
frontier = json.load(open(sys.argv[2], encoding="utf-8"))["data"]
snapshot = json.load(open(sys.argv[3], encoding="utf-8"))
assert status["selection"]["gateState"] == "approved"
assert status["selection"]["approved"] is True
assert status["selection"]["selectedProposal"] == "proposal-b"
assert status["selection"]["proposedProposal"] == "proposal-b"
assert status["selection"]["durableGraphGate"] is True
assert any("implementation" in item["nodeId"] for item in frontier["runnable"])
proposals = [item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "proposal"]
assert len(proposals) == 3 and all(item["state"] == "completed" for item in proposals)
implementation = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
gate_edges = [item for item in snapshot["edges"] if item["kind"] == "gated-by" and item["from"] == implementation["id"]]
assert len(gate_edges) == 1 and gate_edges[0]["to"] == status["selection"]["gateNodeId"]
PY

# Successful selection retries do not mutate or duplicate the child.
bash "$DESIGN_FLOW" select --feature FS-0008 --lane design-lane --proposal proposal-b --json > /dev/null
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "3"
expect_error SELECTION_CONFLICT bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-a --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane other-lane --proposal proposal-b --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --priority 601 --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" select --feature FS-0008 --feature-node FS-0009 \
  --lane design-lane --proposal proposal-b --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "3"

printf 'visual evidence\n' > "$TMP_ROOT/evidence.txt"
expect_error OUTCOME_INCOMPLETE bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json
test ! -e "$FEEDBACK_LOG"

python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
next(item for item in value["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")["state"] = "completed"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 --lane design-lane \
  --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json > "$TMP_ROOT/improvement.json"
test "$(wc -l < "$FEEDBACK_LOG" | tr -d ' ')" = "1"
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "4"

# The same request is fully idempotent across feedback and graph ownership.
bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 --lane design-lane \
  --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json > /dev/null
test "$(wc -l < "$FEEDBACK_LOG" | tr -d ' ')" = "1"
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "4"
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --request-id review-001 --message "Needs a clearer hierarchy" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane other-lane --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --priority 551 --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json
expect_error INTENT_CONFLICT bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 --feature-node FS-0009 \
  --lane design-lane --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json
expect_error REQUEST_ID_CONFLICT bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --request-id review-001-other --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "4"

expect_error OUTCOME_INCOMPLETE bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --request-id review-002 --message "Try another forward pass" --json

python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
improvement = next(item for item in value["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "improvement")
assert improvement["kind"] == "feedback" and improvement["state"] == "pending"
implementation = next(item for item in value["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
assert any(edge["kind"] == "feedback-for" and edge["from"] == improvement["id"] and edge["to"] == implementation["id"] for edge in value["edges"])
assert implementation["state"] == "completed"
improvement["state"] = "completed"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 --lane design-lane \
  --request-id review-002 --message "Try another forward pass" --json > "$TMP_ROOT/improvement-2.json"
bash "$DESIGN_FLOW" status --feature FS-0008 --json > "$TMP_ROOT/status.json"
python3 - "$TMP_ROOT/status.json" "$SNAPSHOT" "$GRAPH_LOG" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
snapshot = json.load(open(sys.argv[2], encoding="utf-8"))
requests = [json.loads(line) for line in open(sys.argv[3], encoding="utf-8")]
assert len(status["proposals"]) == 3
assert status["selection"]["gateState"] == "approved"
assert [item["feedbackId"] for item in status["improvements"]] == ["FB-0001","FB-0002"]
assert [item["sequence"] for item in status["improvements"]] == [1,2]
implementation = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
assert implementation["state"] == "completed"
for request in requests:
    assert set(request) == {"schemaVersion","command","requestId","graphId","expectedRevision","definition","gateNodeId","decision"}
    encoded = json.dumps(request)
    for forbidden in ("actorBinding","proofFd","privateKey","authorityKey","holderScope"):
        assert forbidden not in encoded
PY

# The same flow ID in a second feature receives disjoint stable graph IDs and
# an independently anchored artifact root. Pause snapshot delivery after the
# feature root descriptor opens, replace the pathname with a symlink, and prove
# new writes still land only in the originally opened feature directory.
export DESIGN_SMOKE_SNAPSHOT_READY="$TMP_ROOT/race-ready"
export DESIGN_SMOKE_SNAPSHOT_GO="$TMP_ROOT/race-go"
mkdir -p "$TMP_ROOT/evil-feature"
printf '{"id":"EVIL","slug":"evil"}\n' > "$TMP_ROOT/evil-feature/status.json"
bash "$DESIGN_FLOW" start --feature FS-0009 --brief "$TMP_ROOT/brief.md" \
  --lane other-lane --title "Second feature" --json > "$TMP_ROOT/feature-two-start.json" &
race_pid=$!
for _ in $(seq 1 500); do
  [ -e "$DESIGN_SMOKE_SNAPSHOT_READY" ] && break
  sleep 0.01
done
test -e "$DESIGN_SMOKE_SNAPSHOT_READY"
mv "$FEATURE_TWO_DIR" "$TMP_ROOT/feature-two-opened"
ln -s "$TMP_ROOT/evil-feature" "$FEATURE_TWO_DIR"
touch "$DESIGN_SMOKE_SNAPSHOT_GO"
wait "$race_pid"
test -f "$TMP_ROOT/feature-two-opened/work/design-options/proposal-a/prompt.md"
test ! -e "$TMP_ROOT/evil-feature/work"
unlink "$FEATURE_TWO_DIR"
mv "$TMP_ROOT/feature-two-opened" "$FEATURE_TWO_DIR"
unset DESIGN_SMOKE_SNAPSHOT_READY DESIGN_SMOKE_SNAPSHOT_GO

bash "$DESIGN_FLOW" status --feature FS-0008 --json > "$TMP_ROOT/status-feature-one.json"
bash "$DESIGN_FLOW" status --feature FS-0009 --json > "$TMP_ROOT/status-feature-two.json"
python3 - "$TMP_ROOT/status-feature-one.json" "$TMP_ROOT/status-feature-two.json" "$SNAPSHOT" <<'PY'
import json, sys
one = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
two = json.load(open(sys.argv[2], encoding="utf-8"))["data"]
snapshot = json.load(open(sys.argv[3], encoding="utf-8"))
assert one["flowId"] == two["flowId"] == "design"
assert one["featureId"] == "FS-0008" and two["featureId"] == "FS-0009"
one_ids = {node["id"] for node in snapshot["nodes"] if node.get("metadata",{}).get("designFlow",{}).get("featureId") == "FS-0008"}
two_ids = {node["id"] for node in snapshot["nodes"] if node.get("metadata",{}).get("designFlow",{}).get("featureId") == "FS-0009"}
assert one_ids and two_ids and one_ids.isdisjoint(two_ids)
assert one["selection"]["gateNodeId"] != two["selection"]["gateNodeId"]
assert one["selection"]["approved"] is True and two["selection"]["approved"] is False
PY

# Artifact reads reject hard-linked leaves so a writable alias cannot change
# evidence behind an accepted descriptor identity.
printf 'hard-link source\n' > "$TMP_ROOT/hard-link-source.md"
unlink "$FEATURE_DIR/work/design-options/proposal-a/README.md"
ln "$TMP_ROOT/hard-link-source.md" "$FEATURE_DIR/work/design-options/proposal-a/README.md"
expect_error IO_ERROR bash "$DESIGN_FLOW" status --feature FS-0008 --json
unlink "$FEATURE_DIR/work/design-options/proposal-a/README.md"
printf '# Proposal A result\n' > "$FEATURE_DIR/work/design-options/proposal-a/README.md"

# Status inventories evidence but fails closed on a symlinked proposal folder.
mv "$FEATURE_DIR/work/design-options/proposal-c" "$FEATURE_DIR/work/design-options/proposal-c-real"
ln -s "$FEATURE_DIR/work/design-options/proposal-c-real" "$FEATURE_DIR/work/design-options/proposal-c"
expect_error IO_ERROR bash "$DESIGN_FLOW" status --feature FS-0008 --json

grep -q 'control-owned marker' "$OPERATOR_DIR/graph/DO-NOT-READ"
printf 'v5 design flow smoke ok: %s\n' "$TMP_ROOT"
