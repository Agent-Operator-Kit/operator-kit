#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEDULER="$KIT_ROOT/scripts/operator-scheduler.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-scheduler.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

python3 - "$TMP_ROOT" <<'PY'
import copy
import datetime as dt
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = "sha256:" + "0" * 64


def node(node_id, kind="task", state=None, priority=0, scheduler=None, execution=None):
    families = {
        "goal": ("planned", "planned"), "feature": ("planned", "planned"),
        "lane": ("planned", "planned"), "human-gate": ("pending", "pending"),
    }
    initial, default_state = families.get(kind, ("pending", "pending"))
    metadata = {}
    if scheduler is not None:
        metadata["scheduler"] = scheduler
    if execution is not None:
        metadata["execution"] = execution
    return {
        "id": node_id, "kind": kind, "title": node_id, "initialState": initial,
        "priority": priority, "metadata": metadata, "state": state or default_state,
    }


def edge(kind, source, target, metadata=None):
    if metadata is None:
        metadata = {"protectedTransitions": ["active", "completed"]} if kind == "gated-by" else {}
    return {"id": f"{kind}:{source}:{target}", "kind": kind, "from": source, "to": target, "metadata": metadata}


def snapshot(graph_id="scheduler-test"):
    return {
        "schemaVersion": "operator.control-snapshot/v1", "graphId": graph_id,
        "revision": 1, "definitionRevision": 1, "definitionHash": digest,
        "updatedAt": "2026-07-22T00:00:00Z", "eventCount": 1,
        "nodes": [], "edges": [], "leases": {}, "leaseFences": {},
        "executionStarted": {}, "reconciliations": {}, "bindingGenerations": {},
        "authorityKeyId": "control-test", "authorityHash": digest,
    }


def add_work(value, work, lane_id=None):
    lane_id = lane_id or f"lane-{work['id']}"
    if not any(item["id"] == lane_id for item in value["nodes"]):
        value["nodes"].append(node(lane_id, "lane"))
    value["nodes"].append(work)
    value["edges"].append(edge("assigned-to", work["id"], lane_id))


def write(name, value):
    (root / name).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")


empty = snapshot("empty")
write("empty.json", empty)
write("bad-envelope-command-object.json", {"ok": True, "command": {}, "data": empty})

matrix = snapshot("matrix")
add_work(matrix, node("chain-root", state="completed"))
add_work(matrix, node("chain-ready", priority=700))
matrix["edges"].append(edge("depends-on", "chain-ready", "chain-root"))
add_work(matrix, node("chain-wait", priority=690))
matrix["edges"].append(edge("depends-on", "chain-wait", "chain-ready"))

add_work(matrix, node("diamond-left", state="completed"))
add_work(matrix, node("diamond-right", state="completed"))
add_work(matrix, node("diamond-leaf", priority=680))
matrix["edges"].extend([
    edge("depends-on", "diamond-leaf", "diamond-left"),
    edge("depends-on", "diamond-leaf", "diamond-right"),
])

add_work(matrix, node("parallel-a", priority=670, scheduler={"claims": {"files": ["a.txt"], "contracts": ["alpha"]}}))
add_work(matrix, node("parallel-b", priority=660, scheduler={"claims": {"files": ["b.txt"], "resources": ["sim-b"]}}))
add_work(matrix, node("collision-high", priority=650, scheduler={"claims": {"files": ["shared.txt"]}}))
add_work(matrix, node("collision-low", priority=640, scheduler={"claims": {"files": ["shared.txt"]}}))

matrix["nodes"].append(node("gate-pending", "human-gate"))
add_work(matrix, node("gated-pending", priority=630))
matrix["edges"].append(edge("gated-by", "gated-pending", "gate-pending"))
matrix["nodes"].append(node("gate-approved", "human-gate", state="approved"))
add_work(matrix, node("gated-approved", priority=620))
matrix["edges"].append(edge("gated-by", "gated-approved", "gate-approved"))

add_work(matrix, node("paused-node", state="blocked", priority=610))
matrix["nodes"].append(node("lane-paused", "lane", state="blocked"))
add_work(matrix, node("paused-lane-work", priority=600), "lane-paused")

add_work(matrix, node("live-lease", priority=590, scheduler={"claims": {"resources": ["live-resource"]}}, execution={"idempotent": True, "reclaimable": True}))
add_work(matrix, node("live-conflict", priority=585, scheduler={"claims": {"resources": ["live-resource"]}}))
add_work(matrix, node("stale-safe", priority=580, execution={"idempotent": True, "reclaimable": True}))
add_work(matrix, node("stale-unsafe", priority=575, execution={"idempotent": False, "reclaimable": False}))
add_work(matrix, node("failed-upstream", state="failed"))
add_work(matrix, node("failed-dependent", priority=570))
matrix["edges"].append(edge("depends-on", "failed-dependent", "failed-upstream"))
matrix["nodes"].append(node("unassigned", priority=560))

holder_hash = "sha256:" + "1" * 64
matrix["bindingGenerations"]["lane-binding"] = {"generation": 1, "bindingHash": holder_hash}
lease_cases = (
    # Wall expiry is older than snapshot.updatedAt, but monotonic evidence says live.
    ("live-lease", "2026-07-21T23:59:00Z", 20),
    # Wall expiry is newer than snapshot.updatedAt, but monotonic evidence says stale.
    ("stale-safe", "2026-07-22T00:10:00Z", 2),
    ("stale-unsafe", "2026-07-22T00:10:00Z", 2),
)
for node_id, expires, expires_monotonic_ns in lease_cases:
    acquired = "2026-07-21T23:50:00Z"
    matrix["leases"][node_id] = {
        "schemaVersion": "operator.ownership-lease/v1", "nodeId": node_id,
        "leaseId": f"lease-{node_id}",
        "holder": {"actorType": "lane", "actorId": "lane-test", "bindingId": "lane-binding",
                   "bindingGeneration": 1, "bindingHash": holder_hash,
                   "scope": f"scope:{node_id}", "laneNodeId": f"lane-{node_id}"},
        "acquiredAt": acquired, "renewedAt": acquired, "expiresAt": expires, "fence": 1,
        "clock": {"hostId": "host", "bootId": "boot", "monotonicSource": "linux-proc-uptime",
                  "acquiredMonotonicNs": 1, "expiresMonotonicNs": expires_monotonic_ns},
    }
    matrix["leaseFences"][node_id] = 1
    matrix["executionStarted"][node_id] = {"revision": 1, "occurredAt": acquired}
write("matrix.json", matrix)
write("matrix-envelope.json", {"ok": True, "command": "snapshot", "data": matrix})
write("clock.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "boot",
                     "monotonicSource": "linux-proc-uptime", "monotonicNs": 10})
write("clock-wrong-host.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "other-host", "bootId": "boot",
                                "monotonicSource": "linux-proc-uptime", "monotonicNs": 10})
write("clock-wrong-boot.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "other-boot",
                                "monotonicSource": "linux-proc-uptime", "monotonicNs": 10})
write("clock-wrong-source.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "boot",
                                  "monotonicSource": "macos-mach-continuous", "monotonicNs": 10})
write("clock-rollback.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "boot",
                              "monotonicSource": "linux-proc-uptime", "monotonicNs": 0})
write("clock-malformed.json", {"schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "boot",
                               "monotonicSource": "linux-proc-uptime"})

unsafe_conflict = snapshot("stale-unsafe-conflict")
unsafe_claims = {
    "files": ["unsafe.txt"], "contracts": ["unsafe-contract"],
    "resources": ["unsafe-resource"],
}
add_work(unsafe_conflict, node("stale-unsafe", priority=1, scheduler={"claims": unsafe_claims},
                               execution={"idempotent": False, "reclaimable": False}))
candidate_claims = copy.deepcopy(unsafe_claims)
candidate_claims["lanes"] = ["lane-stale-unsafe"]
add_work(unsafe_conflict, node("unsafe-conflict", priority=100, scheduler={"claims": candidate_claims}))
unsafe_conflict["bindingGenerations"] = copy.deepcopy(matrix["bindingGenerations"])
unsafe_conflict["leases"]["stale-unsafe"] = copy.deepcopy(matrix["leases"]["stale-unsafe"])
unsafe_conflict["leaseFences"]["stale-unsafe"] = 1
unsafe_conflict["executionStarted"]["stale-unsafe"] = copy.deepcopy(matrix["executionStarted"]["stale-unsafe"])
write("stale-unsafe-conflict.json", unsafe_conflict)

reconciled = snapshot("reconciled-conflict")
reconciled_claims = {
    "files": ["reconciled.txt"], "contracts": ["reconciled-contract"],
    "resources": ["reconciled-resource"],
}
add_work(reconciled, node("reconciled-work", state="blocked", priority=1,
                          scheduler={"claims": reconciled_claims},
                          execution={"idempotent": False, "reclaimable": False}))
reconciled_candidate_claims = copy.deepcopy(reconciled_claims)
reconciled_candidate_claims["lanes"] = ["lane-reconciled-work"]
add_work(reconciled, node("reconciled-conflict", priority=100,
                          scheduler={"claims": reconciled_candidate_claims}))
reconciled["leaseFences"]["reconciled-work"] = 1
reconciled["executionStarted"]["reconciled-work"] = {
    "revision": 1, "occurredAt": "2026-07-21T23:50:00Z",
}
reconciled["reconciliations"]["reconciled-work"] = {
    "leaseId": "reconciled-lease", "fence": 1, "reason": "expired-unsafe",
    "requiredAt": "2026-07-21T23:59:00Z", "priorState": "active",
}
write("reconciled-conflict.json", reconciled)

active_unleased = snapshot("active-unleased-conflict")
active_claims = {
    "files": ["active.txt"], "contracts": ["active-contract"],
    "resources": ["active-resource"],
}
add_work(active_unleased, node("active-work", state="active", priority=1,
                               scheduler={"claims": active_claims}))
active_candidate_claims = copy.deepcopy(active_claims)
active_candidate_claims["lanes"] = ["lane-active-work"]
add_work(active_unleased, node("active-conflict", priority=100,
                               scheduler={"claims": active_candidate_claims}))
active_unleased["leaseFences"]["active-work"] = 1
active_unleased["executionStarted"]["active-work"] = {
    "revision": 1, "occurredAt": "2026-07-21T23:50:00Z",
}
write("active-unleased-conflict.json", active_unleased)

history_only = snapshot("history-only")
add_work(history_only, node("history-work", priority=1,
                            scheduler={"claims": {"files": ["history.txt"]}}))
add_work(history_only, node("history-candidate", priority=100,
                            scheduler={"claims": {"files": ["history.txt"]}}))
history_only["leaseFences"]["history-work"] = 1
history_only["executionStarted"]["history-work"] = {
    "revision": 1, "occurredAt": "2026-07-21T23:50:00Z",
}
write("history-only.json", history_only)

gate_cases = snapshot("gate-transitions")
gate_specs = (
    ("pending-completed", "pending", "completed", 50),
    ("pending-ready", "pending", "ready", 40),
    ("pending-active", "pending", "active", 30),
    ("ready-ready", "ready", "ready", 20),
    ("ready-active", "ready", "active", 10),
)
for work_id, state, protected_transition, priority in gate_specs:
    gate_id = f"gate-{work_id}"
    gate_cases["nodes"].append(node(gate_id, "human-gate"))
    add_work(gate_cases, node(work_id, state=state, priority=priority))
    gate_cases["edges"].append(edge(
        "gated-by", work_id, gate_id,
        {"protectedTransitions": [protected_transition]},
    ))
write("gate-transitions.json", gate_cases)

ordering = snapshot("ordering")
for node_id, priority in (("z-low", 1), ("b-high", 10), ("a-high", 10), ("c-high", 10)):
    add_work(ordering, node(node_id, priority=priority))
write("ordering.json", ordering)

lane_collision = snapshot("lane-collision")
lane_collision["nodes"].append(node("lane-shared", "lane"))
add_work(lane_collision, node("lane-first", priority=2), "lane-shared")
add_work(lane_collision, node("lane-second", priority=1), "lane-shared")
write("lane-collision.json", lane_collision)

claim_collisions = snapshot("claim-collisions")
for kind, claim in (("contracts", "api"), ("resources", "sim"), ("lanes", "virtual-lane")):
    add_work(claim_collisions, node(f"{kind}-first", priority=2, scheduler={"claims": {kind: [claim]}}))
    add_work(claim_collisions, node(f"{kind}-second", priority=1, scheduler={"claims": {kind: [claim]}}))
write("claim-collisions.json", claim_collisions)

missing = snapshot("missing")
add_work(missing, node("orphan"))
missing["edges"].append(edge("depends-on", "orphan", "not-present"))
write("missing.json", missing)

cycle = snapshot("cycle")
add_work(cycle, node("cycle-a"))
add_work(cycle, node("cycle-b"))
cycle["edges"].extend([edge("depends-on", "cycle-a", "cycle-b"), edge("depends-on", "cycle-b", "cycle-a")])
write("cycle.json", cycle)

bad_version = copy.deepcopy(empty)
bad_version["schemaVersion"] = "operator.control-snapshot/v999"
write("bad-version.json", bad_version)

malformed = snapshot("malformed")
add_work(malformed, node("work", execution={"idempotent": True, "reclaimable": True}))
variants = {}
variants["bad-execution.json"] = copy.deepcopy(malformed)
variants["bad-execution.json"]["nodes"][-1]["metadata"]["execution"]["extra"] = True
variants["bad-node.json"] = copy.deepcopy(malformed)
variants["bad-node.json"]["nodes"][-1]["state"] = "invented"
variants["bad-edge.json"] = copy.deepcopy(malformed)
variants["bad-edge.json"]["edges"][0]["kind"] = "invented"
variants["bad-reconciliation.json"] = copy.deepcopy(malformed)
variants["bad-reconciliation.json"]["reconciliations"]["work"] = {"leaseId": "x", "fence": 1, "reason": "invented", "requiredAt": "2026-07-21T00:00:00Z", "priorState": "pending"}
variants["bad-binding-generation.json"] = copy.deepcopy(malformed)
variants["bad-binding-generation.json"]["bindingGenerations"]["bad"] = {"generation": 0, "bindingHash": digest}
variants["bad-binding-generation-key-overlong.json"] = copy.deepcopy(malformed)
variants["bad-binding-generation-key-overlong.json"]["bindingGenerations"]["b" * 129] = {"generation": 1, "bindingHash": digest}
variants["bad-lease.json"] = copy.deepcopy(matrix)
variants["bad-lease.json"]["leases"]["live-lease"]["clock"]["extra"] = True
variants["bad-lease-binding-id-overlong.json"] = copy.deepcopy(matrix)
variants["bad-lease-binding-id-overlong.json"]["leases"]["live-lease"]["holder"]["bindingId"] = "b" * 129
variants["bad-claim-unhashable.json"] = copy.deepcopy(malformed)
variants["bad-claim-unhashable.json"]["nodes"][-1]["metadata"]["scheduler"] = {"claims": {"files": [{}]}}
variants["bad-protected-unhashable.json"] = copy.deepcopy(gate_cases)
next(item for item in variants["bad-protected-unhashable.json"]["edges"] if item["kind"] == "gated-by")["metadata"]["protectedTransitions"] = [{}]
variants["bad-edge-from-object.json"] = copy.deepcopy(malformed)
variants["bad-edge-from-object.json"]["edges"][0]["from"] = {}
variants["bad-edge-kind-object.json"] = copy.deepcopy(malformed)
variants["bad-edge-kind-object.json"]["edges"][0]["kind"] = {}
variants["bad-node-kind-object.json"] = copy.deepcopy(malformed)
variants["bad-node-kind-object.json"]["nodes"][-1]["kind"] = {}
variants["bad-node-state-object.json"] = copy.deepcopy(malformed)
variants["bad-node-state-object.json"]["nodes"][-1]["state"] = {}
variants["bad-lease-actor-object.json"] = copy.deepcopy(matrix)
variants["bad-lease-actor-object.json"]["leases"]["live-lease"]["holder"]["actorType"] = {}
variants["bad-lease-source-object.json"] = copy.deepcopy(matrix)
variants["bad-lease-source-object.json"]["leases"]["live-lease"]["clock"]["monotonicSource"] = {}
variants["bad-reconciliation-reason-object.json"] = copy.deepcopy(reconciled)
variants["bad-reconciliation-reason-object.json"]["reconciliations"]["reconciled-work"]["reason"] = {}
variants["bad-reconciliation-state-object.json"] = copy.deepcopy(reconciled)
variants["bad-reconciliation-state-object.json"]["reconciliations"]["reconciled-work"]["priorState"] = {}
for name, value in variants.items():
    write(name, value)
write("clock-source-object.json", {
    "schemaVersion": "operator.scheduler-clock/v1", "hostId": "host", "bootId": "boot",
    "monotonicSource": {}, "monotonicNs": 10,
})
PY

python3 - "$SCHEDULER" "$TMP_ROOT" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

scheduler, root = sys.argv[1], Path(sys.argv[2])


def run(name, *args, expected=0, stdin=False, clock=None):
    path = root / name
    command = ["bash", scheduler, *args]
    payload = path.read_bytes() if stdin else None
    if clock is not None:
        command.extend(["--clock", str(root / clock)])
    if not stdin:
        command.extend(["--snapshot", str(path)])
    result = subprocess.run(command, input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
    raw = result.stdout if expected == 0 else result.stderr
    assert b"Traceback" not in result.stderr, (command, result.stderr)
    assert len(raw.splitlines()) == 1, (command, raw)
    value = json.loads(raw)
    assert isinstance(value, dict) and value.get("ok") is (expected == 0), (command, value)
    return value


def exclusions(value):
    return {item["nodeId"]: [entry["code"] for entry in item["reasons"]] for item in value["data"]["excluded"]}


empty = run("empty.json", "frontier", "--json", "--explain", stdin=True)
assert empty["data"]["runnable"] == [] and empty["data"]["excluded"] == []

matrix_path = root / "matrix.json"
before = hashlib.sha256(matrix_path.read_bytes()).hexdigest()
matrix = run("matrix.json", "frontier", "--graph", "matrix", "--json", "--explain", clock="clock.json")
again = run("matrix.json", "frontier", "--graph", "matrix", "--json", "--explain", clock="clock.json")
assert matrix == again
assert hashlib.sha256(matrix_path.read_bytes()).hexdigest() == before
runnable = [item["nodeId"] for item in matrix["data"]["runnable"]]
for expected in ("chain-ready", "diamond-leaf", "parallel-a", "parallel-b", "collision-high", "gated-approved", "stale-safe"):
    assert expected in runnable, (expected, runnable)
reason_map = exclusions(matrix)
assert "DEPENDENCY_INCOMPLETE" in reason_map["chain-wait"]
assert "CONFLICT_FILE" in reason_map["collision-low"]
assert "GATE_PENDING" in reason_map["gated-pending"]
assert "PAUSED_NODE" in reason_map["paused-node"]
assert "PAUSED_LANE" in reason_map["paused-lane-work"]
assert "LEASE_LIVE" in reason_map["live-lease"]
assert "CONFLICT_RESOURCE" in reason_map["live-conflict"]
assert "LEASE_STALE_UNSAFE" in reason_map["stale-unsafe"]
assert "DEPENDENCY_FAILED" in reason_map["failed-dependent"]
assert "ASSIGNMENT_MISSING" in reason_map["unassigned"]

envelope = run("matrix-envelope.json", "frontier", "--json", "--explain", clock="clock.json")
assert envelope == matrix

ordering = run("ordering.json", "frontier", "--json", "--explain")
assert [item["nodeId"] for item in ordering["data"]["runnable"]] == ["a-high", "b-high", "c-high", "z-low"]
capacity = run("ordering.json", "frontier", "--json", "--explain", "--capacity", "2")
assert [item["nodeId"] for item in capacity["data"]["runnable"]] == ["a-high", "b-high"]
capacity_reasons = exclusions(capacity)
assert capacity_reasons["c-high"] == ["CAPACITY_EXHAUSTED"]
assert capacity_reasons["z-low"] == ["CAPACITY_EXHAUSTED"]

lane = run("lane-collision.json", "frontier", "--json", "--explain")
assert exclusions(lane)["lane-second"] == ["CONFLICT_LANE"]
claims = run("claim-collisions.json", "frontier", "--json", "--explain")
claim_reasons = exclusions(claims)
assert claim_reasons["contracts-second"] == ["CONFLICT_CONTRACT"]
assert claim_reasons["resources-second"] == ["CONFLICT_RESOURCE"]
assert claim_reasons["lanes-second"] == ["CONFLICT_LANE"]

status = run("matrix.json", "status", "--json", clock="clock.json")
assert status["data"]["liveLeaseCount"] == 1 and status["data"]["staleLeaseCount"] == 2
assert status["data"]["runnableCount"] == len(matrix["data"]["runnable"])
assert status["data"]["trustedClock"]["monotonicNs"] == 10

assert run("matrix.json", "frontier", "--json", expected=5)["error"]["code"] == "TRUSTED_CLOCK_REQUIRED"
for clock_name in ("clock-wrong-host.json", "clock-wrong-boot.json", "clock-wrong-source.json"):
    mismatch = run("matrix.json", "frontier", "--json", expected=5, clock=clock_name)
    assert mismatch["error"]["code"] == "TRUSTED_CLOCK_MISMATCH", clock_name
rollback = run("matrix.json", "frontier", "--json", expected=5, clock="clock-rollback.json")
assert rollback["error"]["code"] == "TRUSTED_CLOCK_ROLLBACK"
invalid_clock = run("matrix.json", "frontier", "--json", expected=5, clock="clock-malformed.json")
assert invalid_clock["error"]["code"] == "TRUSTED_CLOCK_INVALID"

unsafe = run("stale-unsafe-conflict.json", "frontier", "--json", "--explain", clock="clock.json")
unsafe_reasons = exclusions(unsafe)
assert unsafe["data"]["runnable"] == []
assert unsafe_reasons["stale-unsafe"] == ["LEASE_STALE_UNSAFE"]
assert unsafe_reasons["unsafe-conflict"] == [
    "CONFLICT_FILE", "CONFLICT_CONTRACT", "CONFLICT_RESOURCE", "CONFLICT_LANE",
]

reconciled_value = run("reconciled-conflict.json", "frontier", "--json", "--explain")
reconciled_reasons = exclusions(reconciled_value)
assert "RECONCILIATION_REQUIRED" in reconciled_reasons["reconciled-work"]
assert reconciled_reasons["reconciled-conflict"] == [
    "CONFLICT_FILE", "CONFLICT_CONTRACT", "CONFLICT_RESOURCE", "CONFLICT_LANE",
]

active_value = run("active-unleased-conflict.json", "frontier", "--json", "--explain")
active_reasons = exclusions(active_value)
assert "STATE_UNSCHEDULABLE" in active_reasons["active-work"]
assert active_reasons["active-conflict"] == [
    "CONFLICT_FILE", "CONFLICT_CONTRACT", "CONFLICT_RESOURCE", "CONFLICT_LANE",
]

history_value = run("history-only.json", "frontier", "--json", "--explain")
assert [item["nodeId"] for item in history_value["data"]["runnable"]] == ["history-candidate"]
assert exclusions(history_value)["history-work"] == ["CONFLICT_FILE"]

gate_value = run("gate-transitions.json", "frontier", "--json", "--explain")
assert [item["nodeId"] for item in gate_value["data"]["runnable"]] == [
    "pending-completed", "ready-ready",
]
gate_reasons = exclusions(gate_value)
for node_id in ("pending-ready", "pending-active", "ready-active"):
    assert gate_reasons[node_id] == ["GATE_PENDING"], (node_id, gate_reasons[node_id])

assert run("missing.json", "frontier", "--json", expected=5)["error"]["code"] == "MISSING_DEPENDENCY"
assert run("cycle.json", "frontier", "--json", expected=5)["error"]["code"] == "DEPENDENCY_CYCLE"
assert run("bad-version.json", "frontier", "--json", expected=4)["error"]["code"] == "UNKNOWN_SNAPSHOT_VERSION"
assert run("empty.json", "frontier", "--graph", "wrong", "--json", expected=5)["error"]["code"] == "GRAPH_MISMATCH"

expected_codes = {
    "bad-envelope-command-object.json": "INVALID_SNAPSHOT",
    "bad-execution.json": "INVALID_SNAPSHOT",
    "bad-node.json": "INVALID_NODE",
    "bad-edge.json": "INVALID_EDGE",
    "bad-reconciliation.json": "INVALID_SNAPSHOT",
    "bad-binding-generation.json": "INVALID_SNAPSHOT",
    "bad-binding-generation-key-overlong.json": "INVALID_SNAPSHOT",
    "bad-lease.json": "INVALID_SNAPSHOT",
    "bad-lease-binding-id-overlong.json": "INVALID_SNAPSHOT",
    "bad-claim-unhashable.json": "INVALID_NODE",
    "bad-protected-unhashable.json": "INVALID_EDGE",
    "bad-edge-from-object.json": "INVALID_EDGE",
    "bad-edge-kind-object.json": "INVALID_EDGE",
    "bad-node-kind-object.json": "INVALID_NODE",
    "bad-node-state-object.json": "INVALID_NODE",
    "bad-lease-actor-object.json": "INVALID_SNAPSHOT",
    "bad-lease-source-object.json": "INVALID_SNAPSHOT",
    "bad-reconciliation-reason-object.json": "INVALID_SNAPSHOT",
    "bad-reconciliation-state-object.json": "INVALID_SNAPSHOT",
}
for name, code in expected_codes.items():
    assert run(name, "frontier", "--json", expected=5)["error"]["code"] == code, name

bad_clock_source = run("matrix.json", "frontier", "--json", expected=5, clock="clock-source-object.json")
assert bad_clock_source["error"]["code"] == "TRUSTED_CLOCK_INVALID"

text = subprocess.run(["bash", scheduler, "frontier", "--snapshot", str(root / "empty.json")],
                      text=True, stdout=subprocess.PIPE, check=True).stdout
assert "No runnable nodes." in text
PY

echo "operator-v5-scheduler smoke: ok"
