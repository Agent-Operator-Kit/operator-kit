#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="${OPERATOR_KIT_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOOP="$KIT_ROOT/scripts/operator-loop.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-loop.XXXXXX)"
SURVIVOR_PID=""
DESCENDANT_PID=""
cleanup() {
  if [ -n "$SURVIVOR_PID" ]; then
    kill -TERM -- "-$SURVIVOR_PID" 2>/dev/null || true
  fi
  if [ -n "$DESCENDANT_PID" ]; then
    kill -KILL "$DESCENDANT_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_LOOP_TMP:-0}" = 1 ]; then
    printf 'kept loop smoke temp: %s\n' "$TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

FAKE_STATE="$TMP_ROOT/control.json"
FAKE_PROGRAM="$TMP_ROOT/fake-control.py"
export FAKE_STATE

# This is a non-installed host harness. Its mutation endpoint models one fresh
# authorize/event broker session per graph mutation; no production proof key or
# authority selection enters the loop process.
python3 - "$FAKE_PROGRAM" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
path.write_text(r'''#!/usr/bin/env python3
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import time

STATE = Path(os.environ.get("FAKE_STATE", str(Path(sys.argv[0]).with_name("control.json"))))
LOCK = STATE.with_suffix(".lock")
DIGEST = "sha256:" + "0" * 64
HOLDER_HASH = "sha256:" + "1" * 64
BASE = dt.datetime(2026, 7, 22, tzinfo=dt.timezone.utc)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"


def timestamp(seconds):
    return (BASE + dt.timedelta(seconds=seconds)).isoformat(timespec="microseconds").replace("+00:00", "Z")


def load():
    return json.loads(STATE.read_text())


def save(value):
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(canonical(value))
    os.replace(temporary, STATE)


def locked():
    LOCK.touch(mode=0o600, exist_ok=True)
    handle = LOCK.open("r+")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def node(node_id, state="pending", priority=100, safe=True):
    metadata = {"execution": {"idempotent": safe, "reclaimable": safe}}
    return {"id": node_id, "kind": "task", "title": node_id, "initialState": "pending",
            "priority": priority, "metadata": metadata, "state": state}


def lane(node_id):
    return {"id": "lane-" + node_id, "kind": "lane", "title": "lane-" + node_id,
            "initialState": "planned", "priority": 0, "metadata": {}, "state": "planned"}


def initial(scenario):
    count = {"empty": 0, "three": 3, "pause-inflight": 2}.get(scenario, 1)
    nodes = []
    edges = []
    for index in range(count):
        node_id = f"task-{index + 1}"
        nodes.extend((lane(node_id), node(node_id, priority=100 - index)))
        edges.append({"id": "assigned:" + node_id, "kind": "assigned-to", "from": node_id,
                      "to": "lane-" + node_id, "metadata": {}})
    value = {
        "schemaVersion": "fake-control/v1", "scenario": scenario, "revision": 1,
        "clockNs": 10_000_000_000, "nodes": nodes, "edges": edges, "leases": {},
        "leaseFences": {}, "executionStarted": {}, "bindingGenerations": {},
        "reconciliations": {}, "graphEvents": [], "brokerSessions": [],
        "runnerRequests": [], "runnerEnvironments": [], "runnerMode": "succeeded",
        "descendantPids": {},
        "runnerPatch": {}, "mutationMode": "normal",
        "interfaceModes": {"snapshot": "normal", "clock": "normal", "mutation": "normal", "runner": "normal"},
        "corrupt": scenario == "corrupt",
    }
    if scenario in {"failure", "needs-runner"}:
        value["runnerMode"] = "failed" if scenario == "failure" else "needs-runner"
    if scenario in {"concurrency", "pause-inflight", "heartbeat"}:
        value["runnerMode"] = "sleep-succeeded"
    if scenario == "crash-retry":
        value["runnerMode"] = "crash-once"
    if scenario == "crash-survivor":
        value["runnerMode"] = "crash-parent-survive"
    if scenario == "stale":
        lease = make_lease("task-1", "old-lease", 1, 1_000_000_000, 2_000_000_000, 1)
        value["leases"]["task-1"] = lease
        value["leaseFences"]["task-1"] = 1
        value["executionStarted"]["task-1"] = {"revision": 1, "occurredAt": timestamp(1)}
        value["bindingGenerations"]["fake-binding"] = {"generation": 1, "bindingHash": HOLDER_HASH}
    return value


def make_lease(node_id, lease_id, fence, acquired_ns, expires_ns, revision):
    return {
        "schemaVersion": "operator.ownership-lease/v1", "nodeId": node_id, "leaseId": lease_id,
        "holder": {"actorType": "host", "actorId": "fake-host", "bindingId": "fake-binding",
                   "bindingGeneration": 1, "bindingHash": HOLDER_HASH, "scope": "scope:" + node_id,
                   "laneNodeId": "lane-" + node_id},
        "acquiredAt": timestamp(revision), "renewedAt": timestamp(revision),
        "expiresAt": timestamp(revision + max(1, (expires_ns - acquired_ns) // 1_000_000_000)),
        "fence": fence,
        "clock": {"hostId": "fake-host", "bootId": "fake-boot", "monotonicSource": "linux-proc-uptime",
                  "acquiredMonotonicNs": acquired_ns, "expiresMonotonicNs": expires_ns},
    }


def snapshot(value):
    result = {
        "schemaVersion": "operator.control-snapshot/v1", "graphId": "loop-smoke",
        "revision": value["revision"], "definitionRevision": 1, "definitionHash": DIGEST,
        "updatedAt": timestamp(value["revision"] + 100), "eventCount": value["revision"],
        "nodes": value["nodes"], "edges": value["edges"], "leases": value["leases"],
        "leaseFences": value["leaseFences"], "executionStarted": value["executionStarted"],
        "reconciliations": value["reconciliations"], "bindingGenerations": value["bindingGenerations"],
        "authorityKeyId": "fake-authority", "authorityHash": DIGEST,
    }
    if value["corrupt"]:
        result["nodes"][0]["kind"] = "invented"
    return result


def error(code, message, status=4, details=None):
    value = {"ok": False, "error": {"code": code, "message": message}}
    if details is not None:
        value["error"]["details"] = details
    sys.stderr.write(canonical(value))
    raise SystemExit(status)


def stubborn_descendant(label):
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    with locked():
        value = load()
        value["descendantPids"][label] = pid
        save(value)
    return pid


def interface_fault(mode, label):
    if mode.startswith("descendant-"):
        stubborn_descendant(label)
        mode = mode.removeprefix("descendant-")
    if mode == "hang":
        time.sleep(10)
    elif mode == "stdout-over":
        os.write(1, b"x" * (9 * 1024 * 1024))
        time.sleep(10)
    elif mode == "stderr-over":
        os.write(2, b"e" * (9 * 1024 * 1024))
        time.sleep(10)


def configure():
    save(initial(sys.argv[2]))


def set_value():
    with locked():
        value = load()
        target = value
        parts = sys.argv[2].split(".")
        for part in parts[:-1]:
            target = target[part]
        target[parts[-1]] = json.loads(sys.argv[3])
        save(value)


def serve_snapshot():
    with locked():
        value = load()
        mode = value["interfaceModes"]["snapshot"]
    interface_fault(mode, "snapshot")
    with locked():
        value = load()
        print(canonical({"ok": True, "command": "snapshot", "data": snapshot(value)}), end="")


def serve_clock():
    with locked():
        value = load()
        mode = value["interfaceModes"]["clock"]
    interface_fault(mode, "clock")
    with locked():
        value = load()
        print(canonical({"schemaVersion": "operator.scheduler-clock/v1", "hostId": "fake-host",
                         "bootId": "fake-boot", "monotonicSource": "linux-proc-uptime",
                         "monotonicNs": value["clockNs"]}), end="")


def serve_mutation():
    request = json.load(sys.stdin)
    required = {"schemaVersion", "action", "graphId", "nodeId", "tickId", "requestId",
                "expectedRevision", "leaseId", "fence", "targetState", "ttlSeconds"}
    if set(request) != required or request.get("schemaVersion") != "operator.loop-mutation-request/v1":
        error("BAD_REQUEST", "loop mutation request contract mismatch")
    with locked():
        value = load()
        interface_mode = value["interfaceModes"]["mutation"]
        mutation_mode = value["mutationMode"]
    interface_fault(interface_mode, "mutation")
    if mutation_mode.startswith("conflict:") and request["action"] == "acquire":
        error(mutation_mode.split(":", 1)[1], "forced claim conflict")
    if mutation_mode == "renew-error" and request["action"] == "renew":
        error("FENCE_STALE", "forced renewal failure")
    with locked():
        value = load()
        if request["expectedRevision"] != value["revision"]:
            error("REVISION_CONFLICT", "fake revision conflict", details={"actualRevision": value["revision"]})
        action = request["action"]
        node_id = request["nodeId"]
        node_value = next((item for item in value["nodes"] if item["id"] == node_id), None)
        if node_value is None:
            error("INVALID_GRAPH", "missing node")
        data = {}
        if action == "acquire":
            current = value["leases"].get(node_id)
            if current is not None and value["clockNs"] < current["clock"]["expiresMonotonicNs"]:
                error("LEASE_CONFLICT", "lease is live")
            execution = node_value["metadata"].get("execution", {})
            if current is not None and not (execution.get("idempotent") is True and execution.get("reclaimable") is True
                                            and node_value["state"] in {"pending", "ready", "blocked"}):
                error("RECONCILIATION_REQUIRED", "stale owner is unsafe")
            fence = value["leaseFences"].get(node_id, 0) + 1
            ttl = request["ttlSeconds"]
            lease = make_lease(node_id, request["leaseId"], fence, value["clockNs"],
                               value["clockNs"] + ttl * 1_000_000_000, value["revision"] + 1)
            value["leases"][node_id] = lease
            value["leaseFences"][node_id] = fence
            value["executionStarted"].setdefault(node_id, {"revision": value["revision"] + 1,
                                                            "occurredAt": timestamp(value["revision"] + 1)})
            value["bindingGenerations"]["fake-binding"] = {"generation": 1, "bindingHash": HOLDER_HASH}
            data = {"lease": lease, "reclaimed": current is not None}
            command = "lease acquire"
        elif action == "renew":
            lease = value["leases"].get(node_id)
            if lease is None or lease["leaseId"] != request["leaseId"] or lease["fence"] != request["fence"]:
                error("FENCE_STALE", "renewal is stale")
            lease["renewedAt"] = timestamp(value["revision"] + 1)
            lease["expiresAt"] = timestamp(value["revision"] + 1 + request["ttlSeconds"])
            lease["clock"]["expiresMonotonicNs"] = value["clockNs"] + request["ttlSeconds"] * 1_000_000_000
            data = {"lease": lease}
            command = "lease renew"
        elif action == "transition":
            lease = value["leases"].get(node_id)
            if lease is None or lease["leaseId"] != request["leaseId"] or lease["fence"] != request["fence"]:
                error("FENCE_STALE", "transition is stale")
            source = node_value["state"]
            target = request["targetState"]
            allowed = {"pending": {"ready", "active", "blocked", "cancelled"},
                       "ready": {"active", "blocked", "cancelled"},
                       "active": {"blocked", "completed", "failed", "cancelled"},
                       "failed": {"ready", "cancelled"}}
            if target not in allowed.get(source, set()):
                error("INVALID_TRANSITION", "transition is invalid")
            node_value["state"] = target
            data = {"nodeId": node_id, "from": source, "to": target}
            command = "transition"
        elif action == "release":
            lease = value["leases"].get(node_id)
            if lease is None or lease["leaseId"] != request["leaseId"] or lease["fence"] != request["fence"]:
                error("FENCE_STALE", "release is stale")
            del value["leases"][node_id]
            data = {"nodeId": node_id, "leaseId": request["leaseId"], "fence": request["fence"]}
            command = "lease release"
        else:
            error("BAD_REQUEST", "unknown loop mutation action")
        value["revision"] += 1
        value["clockNs"] += 100_000_000
        value["graphEvents"].append({"action": action, "nodeId": node_id, "requestId": request["requestId"]})
        value["brokerSessions"].append({"requestId": request["requestId"], "phases": ["authorize", "event"],
                                        "oneShot": True, "authoritySelectedByHost": True})
        result = {"ok": True, "command": command, "requestId": request["requestId"],
                  "revision": value["revision"], "data": data}
        save(value)
        if mutation_mode == "bad-revision" and action == "acquire":
            result["revision"] += 1
        elif mutation_mode == "bad-acquire-data" and action == "acquire":
            result["data"] = {"lease": data["lease"], "reclaimed": "false"}
        elif mutation_mode == "bad-lease-timestamp" and action == "acquire":
            result["data"]["lease"]["acquiredAt"] = result["data"]["lease"]["acquiredAt"].replace("Z", "+00:00")
        elif mutation_mode == "bad-lease-fence" and action == "acquire":
            result["data"]["lease"]["fence"] = 999
        elif mutation_mode == "bad-lease-tombstone" and action == "acquire":
            result["data"]["lease"]["fence"] = value["leaseFences"].get(node_id, 1) - 1
        elif mutation_mode == "foreign-lease-clock" and action == "acquire":
            result["data"]["lease"]["clock"].update({"hostId": "foreign-host", "bootId": "foreign-boot",
                                                        "monotonicSource": "macos-mach-continuous"})
        elif mutation_mode == "bad-holder-assignment" and action == "acquire":
            result["data"]["lease"]["holder"].update({"scope": "lane:foreign", "laneNodeId": "lane-foreign"})
        elif mutation_mode == "bad-reclaimed" and action == "acquire":
            result["data"]["reclaimed"] = False
        elif mutation_mode == "bad-renew-data" and action == "renew":
            result["data"] = {"lease": dict(data["lease"], fence=data["lease"]["fence"] + 1)}
        elif mutation_mode == "bad-renew-reshape" and action == "renew":
            result["data"]["lease"]["holder"] = dict(result["data"]["lease"]["holder"], actorId="reshaped")
        elif mutation_mode == "bad-transition-data" and action == "transition":
            result["data"] = {"nodeId": node_id, "from": "invented", "to": request["targetState"]}
        elif mutation_mode == "bad-release-data" and action == "release":
            result["data"] = {"nodeId": "invented", "leaseId": request["leaseId"], "fence": request["fence"]}
        print(canonical(result), end="")


def serve_runner():
    request = json.load(sys.stdin)
    required = {"schemaVersion", "tickId", "runId", "idempotencyKey", "graphId", "node", "lease"}
    if set(request) != required or request.get("schemaVersion") != "operator.runner-request/v1":
        error("BAD_RUNNER_REQUEST", "runner request contract mismatch")
    with locked():
        value = load()
        value["runnerRequests"].append(request)
        value["runnerEnvironments"].append(sorted(os.environ))
        mode = value["runnerMode"]
        interface_mode = value["interfaceModes"]["runner"]
        runner_patch = value["runnerPatch"]
        if mode == "crash-once":
            value["runnerMode"] = "succeeded"
        if mode == "crash-parent-survive":
            value["runnerMode"] = "succeeded"
            value["survivorPid"] = os.getpid()
        save(value)
    interface_fault(interface_mode, "runner")
    if mode == "crash-once":
        os.kill(os.getppid(), signal.SIGKILL)
        raise SystemExit(99)
    if mode == "crash-parent-survive":
        os.kill(os.getppid(), signal.SIGKILL)
        time.sleep(10)
        raise SystemExit(98)
    if mode == "sleep-succeeded":
        time.sleep(3.2)
        mode = "succeeded"
    if mode == "nonzero-unsafe-stderr":
        os.write(2, b"line\n\x1b[31mred\x00\xff")
        raise SystemExit(9)
    status = "failed" if mode == "failed" else mode
    result = {"schemaVersion": "operator.runner-result/v1", "runId": request["runId"],
              "nodeId": request["node"]["nodeId"], "leaseId": request["lease"]["leaseId"],
              "fence": request["lease"]["fence"], "status": status,
              "summary": "fake " + status,
              "error": {"code": "FAKE_FAILURE"} if status == "failed" else None}
    result.update(runner_patch)
    print(canonical(result), end="")


if len(sys.argv) > 1 and sys.argv[1] == "configure":
    configure()
elif len(sys.argv) > 1 and sys.argv[1] == "set":
    set_value()
else:
    role = Path(sys.argv[0]).name
    {"snapshot": serve_snapshot, "clock": serve_clock, "mutation": serve_mutation,
     "runner": serve_runner}[role]()
''')
path.chmod(0o700)
PY

for role in snapshot clock mutation runner; do
  ln -s "$FAKE_PROGRAM" "$TMP_ROOT/$role"
done

FAKE_SCHEDULER="$TMP_ROOT/fake-scheduler.py"
python3 - "$FAKE_SCHEDULER" "$KIT_ROOT/scripts/operator-scheduler.sh" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
real = sys.argv[2]
path.write_text(f'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
mode = os.environ.get("FAKE_SCHEDULER_MODE", "normal")
if mode == "hang":
    time.sleep(10)
if mode == "stdout-over":
    os.write(1, b"x" * (9 * 1024 * 1024))
    raise SystemExit(0)
if mode == "stderr-over":
    os.write(2, b"e" * (9 * 1024 * 1024))
    raise SystemExit(9)
result = subprocess.run(["bash", {real!r}, *sys.argv[1:]], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, check=False)
if result.returncode != 0:
    os.write(2, result.stderr)
    raise SystemExit(result.returncode)
value = json.loads(result.stdout)
data = value["data"]
if mode == "runnable-mismatch" and value["command"] == "frontier" and data["runnable"]:
    data["runnable"][0]["title"] = "invented-title"
elif mode == "runnable-duplicate" and value["command"] == "frontier" and data["runnable"]:
    data["runnable"].append(data["runnable"][0])
elif mode == "candidate-omitted" and value["command"] == "frontier":
    (data["runnable"] if data["runnable"] else data["excluded"]).pop()
elif mode == "status-extra" and value["command"] == "status":
    data["invented"] = True
os.write(1, (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\\n").encode())
''')
path.chmod(0o700)
PY

export OPERATOR_LOOP_SNAPSHOT_COMMAND="$TMP_ROOT/snapshot"
export OPERATOR_LOOP_CLOCK_COMMAND="$TMP_ROOT/clock"
export OPERATOR_LOOP_MUTATION_COMMAND="$TMP_ROOT/mutation"
export OPERATOR_LOOP_RUNNER_COMMAND="$TMP_ROOT/runner"
export OPERATOR_LOOP_LEASE_TTL_SECONDS=3
export OPERATOR_LOOP_HEARTBEAT_SECONDS=1
export OPERATOR_LOOP_INTERFACE_TIMEOUT_SECONDS=2
export OPERATOR_LOOP_SCHEDULER_TIMEOUT_SECONDS=2
export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=5
export OPERATOR_LOOP_TEST_MODE=1

CONFIG_SEQ=0

fail() {
  printf 'operator v5 loop smoke failed: %s\n' "$1" >&2
  exit 1
}

configure() {
  python3 "$FAKE_PROGRAM" configure "$1"
  CONFIG_SEQ=$((CONFIG_SEQ + 1))
  OPERATOR_DIR="$TMP_ROOT/operator-$1-$CONFIG_SEQ"
  mkdir -p "$OPERATOR_DIR"
  export OPERATOR_DIR
}

set_fake() {
  python3 "$FAKE_PROGRAM" set "$1" "$2"
}

assert_json() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
expression = sys.argv[2]
assert eval(expression, {"value": value}), value
PY
}

assert_descendant_gone() {
  local label="$1"
  DESCENDANT_PID="$(python3 - "$FAKE_STATE" "$label" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["descendantPids"][sys.argv[2]])
PY
)"
  for _ in $(seq 1 250); do
    if ! kill -0 "$DESCENDANT_PID" 2>/dev/null; then
      DESCENDANT_PID=""
      return
    fi
    sleep 0.02
  done
  fail "$label descendant survived contained process-group termination (pid $DESCENDANT_PID)"
}

expect_error() {
  local expected="$1"
  shift
  local output="$TMP_ROOT/error-output.json"
  local error="$TMP_ROOT/error.json"
  local result
  set +e
  "$@" >"$output" 2>"$error"
  result="$?"
  set -e
  [ "$result" -ne 0 ] || fail "expected failure: $*"
  [ ! -s "$output" ] || fail "failure emitted stdout: $*"
  [ "$(wc -l < "$error" | tr -d ' ')" -eq 1 ] || fail "failure did not emit exactly one JSON record: $*"
  ! grep -q Traceback "$error" || fail "failure emitted traceback: $*"
  assert_json "$error" "value['error']['code'] == '$expected'"
}

# Empty frontier and dry-run are successful and mutation-free.
configure empty
bash "$LOOP" tick --max-actions 4 --json > "$TMP_ROOT/empty.json"
assert_json "$TMP_ROOT/empty.json" "value['data']['claimedCount'] == 0"
configure three
before="$(shasum -a 256 "$FAKE_STATE" | awk '{print $1}')"
bash "$LOOP" tick --dry-run --max-actions 2 --json > "$TMP_ROOT/dry-run.json"
after="$(shasum -a 256 "$FAKE_STATE" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "dry-run mutated trusted control state"
[ ! -e "$OPERATOR_DIR/loop" ] || fail "dry-run created durable loop state"
assert_json "$TMP_ROOT/dry-run.json" "value['data']['claimedCount'] == 0 and len(value['data']['frontier']['runnable']) == 2"

# A trusted host retains the OPERATOR_DIR capability lock while its contained
# loop runs. Once a real V5 graph exists, the loop singleton must remain an
# independent boundary and must not self-deadlock against that host lock.
mkdir -p "$OPERATOR_DIR/graph"
python3 - "$OPERATOR_DIR" "$LOOP" "$TMP_ROOT/host-locked-dry-run.json" <<'PY'
import fcntl, os, subprocess, sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    with open(sys.argv[3], "wb") as output:
        result = subprocess.run(["bash", sys.argv[2], "tick", "--dry-run", "--max-actions", "2", "--json"],
                                env=os.environ, stdout=output, stderr=subprocess.PIPE,
                                check=False, timeout=10)
    assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
finally:
    os.close(descriptor)
PY
assert_json "$TMP_ROOT/host-locked-dry-run.json" "value['data']['claimedCount'] == 0 and len(value['data']['frontier']['runnable']) == 2"
rmdir "$OPERATOR_DIR/graph"

# Capacity is a hard upper bound and every mutation gets a distinct, one-shot
# host-selected authorize/event broker session.
bash "$LOOP" tick --max-actions 2 --json > "$TMP_ROOT/bounded.json"
assert_json "$TMP_ROOT/bounded.json" "value['data']['claimedCount'] == 2"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert sum(item["state"] == "completed" for item in value["nodes"] if item["kind"] == "task") == 2
sessions = value["brokerSessions"]
assert sessions and len({item["requestId"] for item in sessions}) == len(sessions)
assert all(item["phases"] == ["authorize", "event"] and item["oneShot"]
           and item["authoritySelectedByHost"] for item in sessions)
PY

# Success and failure append durable loop result events; failure never becomes success.
configure success
bash "$LOOP" tick --json > "$TMP_ROOT/success.json"
assert_json "$TMP_ROOT/success.json" "value['data']['actions'][0]['outcome'] == 'succeeded'"
configure failure
bash "$LOOP" tick --json > "$TMP_ROOT/failure.json"
assert_json "$TMP_ROOT/failure.json" "value['data']['actions'][0]['outcome'] == 'failed'"
python3 - "$FAKE_STATE" "$OPERATOR_DIR/loop/events.jsonl" <<'PY'
import json, sys
control = json.load(open(sys.argv[1]))
task = next(item for item in control["nodes"] if item["kind"] == "task")
assert task["state"] == "failed", task
events = [json.loads(line) for line in open(sys.argv[2])]
assert events[-1]["outcome"] == "failed" and events[-1]["runnerResult"]["status"] == "failed"
PY

# An absent installed runner fails before any claim; needs-runner is rejected as
# a runner result rather than treated as success.
configure success
saved_runner="$OPERATOR_LOOP_RUNNER_COMMAND"
unset OPERATOR_LOOP_RUNNER_COMMAND
expect_error NEEDS_RUNNER bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['graphEvents'] == []"
export OPERATOR_LOOP_RUNNER_COMMAND="$saved_runner"
configure needs-runner
bash "$LOOP" tick --json > "$TMP_ROOT/needs-runner.json"
assert_json "$TMP_ROOT/needs-runner.json" "value['data']['actions'][0]['outcome'] == 'failed' and value['data']['actions'][0]['runnerResult']['error']['code'] == 'RUNNER_PROTOCOL'"

# Pause/resume are idempotent. Pause linearizes before the next claim while the
# current runner and its heartbeat remain alive.
configure success
bash "$LOOP" pause --reason maintenance --json > "$TMP_ROOT/pause-1.json"
state_hash="$(shasum -a 256 "$OPERATOR_DIR/loop/state.json" | awk '{print $1}')"
bash "$LOOP" pause --reason ignored-repeat --json > "$TMP_ROOT/pause-2.json"
[ "$state_hash" = "$(shasum -a 256 "$OPERATOR_DIR/loop/state.json" | awk '{print $1}')" ] || fail "repeated pause was not idempotent"
bash "$LOOP" tick --json > "$TMP_ROOT/paused-tick.json"
assert_json "$TMP_ROOT/paused-tick.json" "value['data']['claimedCount'] == 0 and value['data']['paused'] is True"
bash "$LOOP" resume --json > "$TMP_ROOT/resume-1.json"
state_hash="$(shasum -a 256 "$OPERATOR_DIR/loop/state.json" | awk '{print $1}')"
bash "$LOOP" resume --json > "$TMP_ROOT/resume-2.json"
[ "$state_hash" = "$(shasum -a 256 "$OPERATOR_DIR/loop/state.json" | awk '{print $1}')" ] || fail "repeated resume was not idempotent"

configure pause-inflight
bash "$LOOP" tick --max-actions 2 --json > "$TMP_ROOT/pause-inflight-tick.json" &
tick_pid="$!"
for _ in $(seq 1 50); do
  python3 - "$FAKE_STATE" <<'PY' && break || true
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["runnerRequests"] else 1)
PY
  sleep 0.05
done
bash "$LOOP" pause --reason stop-next --json > "$TMP_ROOT/pause-inflight.json"
wait "$tick_pid"
assert_json "$TMP_ROOT/pause-inflight-tick.json" "value['data']['claimedCount'] == 1"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert len(value["runnerRequests"]) == 1
assert any(item["action"] == "renew" for item in value["graphEvents"]), value["graphEvents"]
PY

# Two simultaneous ticks cannot double-dispatch the same work.
configure concurrency
set +e
bash "$LOOP" tick --json > "$TMP_ROOT/concurrent-a.json" 2> "$TMP_ROOT/concurrent-a.err" &
first_pid="$!"
sleep 0.1
bash "$LOOP" tick --json > "$TMP_ROOT/concurrent-b.json" 2> "$TMP_ROOT/concurrent-b.err"
second_status="$?"
wait "$first_pid"
first_status="$?"
set -e
[ "$first_status" -eq 0 ] || fail "first concurrent tick failed"
[ "$second_status" -ne 0 ] || fail "second concurrent tick acquired singleton lease"
assert_json "$TMP_ROOT/concurrent-b.err" "value['error']['code'] == 'LOOP_BUSY'"
assert_json "$FAKE_STATE" "len(value['runnerRequests']) == 1"

# A stale safe owner is reclaimed with a higher fence.
configure stale
bash "$LOOP" tick --json > "$TMP_ROOT/stale.json"
assert_json "$TMP_ROOT/stale.json" "value['data']['actions'][0]['fence'] == 2 and value['data']['actions'][0]['outcome'] == 'succeeded'"

# A hard loop crash leaves pending work leased. After monotonic expiry the same
# idempotency key is retried through RM-0007-style stale-owner recovery.
configure crash-retry
crash_status="$(python3 - "$LOOP" "$TMP_ROOT/crash.json" "$TMP_ROOT/crash.err" <<'PY'
import os, subprocess, sys
with open(sys.argv[2], "wb") as output, open(sys.argv[3], "wb") as error:
    result = subprocess.run(["bash", sys.argv[1], "tick", "--json"], env=os.environ,
                            stdout=output, stderr=error, check=False)
print(result.returncode)
PY
)"
[ "$crash_status" -ne 0 ] || fail "crash scenario did not stop the loop"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
assert value["leases"]["task-1"]["fence"] == 1
value["clockNs"] = value["leases"]["task-1"]["clock"]["expiresMonotonicNs"]
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
bash "$LOOP" tick --json > "$TMP_ROOT/crash-retry.json"
assert_json "$TMP_ROOT/crash-retry.json" "value['data']['actions'][0]['fence'] == 2 and value['data']['actions'][0]['outcome'] == 'succeeded'"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
requests = value["runnerRequests"]
assert len(requests) == 2
assert requests[0]["idempotencyKey"] == requests[1]["idempotencyKey"]
PY

# Corrupt scheduler input fails closed before any claim.
configure corrupt
expect_error INVALID_NODE bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['graphEvents'] == []"

# Exact mutation result binding rejects bad revisions and action-specific data.
# A committed acquire with a malformed reply is recovered by its requested
# lease ID, failed, released, and recorded without invoking the runner.
for mutation_mode in bad-revision bad-acquire-data; do
  configure "mutation-$mutation_mode"
  set_fake mutationMode "\"$mutation_mode\""
  bash "$LOOP" tick --json > "$TMP_ROOT/$mutation_mode.json"
  assert_json "$TMP_ROOT/$mutation_mode.json" "value['data']['actions'][0]['outcome'] == 'failed'"
  python3 - "$FAKE_STATE" "$OPERATOR_DIR/loop/events.jsonl" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
task = next(item for item in value["nodes"] if item["kind"] == "task")
assert task["state"] == "failed" and value["leases"] == {} and value["runnerRequests"] == []
assert len(open(sys.argv[2]).readlines()) == 1
PY
done

# Public leases are bound to exact RM-0007 time, clock, holder-assignment,
# tombstone/fence, TTL, and reclaim semantics before any runner request.
for lease_mode in bad-lease-timestamp bad-lease-fence bad-lease-tombstone foreign-lease-clock bad-holder-assignment; do
  configure "lease-$lease_mode"
  set_fake mutationMode "\"$lease_mode\""
  bash "$LOOP" tick --json > "$TMP_ROOT/$lease_mode.json"
  assert_json "$TMP_ROOT/$lease_mode.json" "value['data']['actions'][0]['outcome'] == 'failed'"
  assert_json "$FAKE_STATE" "value['runnerRequests'] == [] and value['leases'] == {}"
done

configure lease-false-reclaim
set_fake mutationMode '"bad-reclaimed"'
# Install one expired, safely reclaimable prior lease and its fence tombstone.
python3 - "$FAKE_STATE" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["leases"]["task-1"] = {
    "schemaVersion": "operator.ownership-lease/v1", "nodeId": "task-1", "leaseId": "prior-lease",
    "holder": {"actorType": "host", "actorId": "fake-host", "bindingId": "fake-binding",
               "bindingGeneration": 1, "bindingHash": "sha256:" + "1" * 64,
               "scope": "scope:task-1", "laneNodeId": "lane-task-1"},
    "acquiredAt": "2026-07-22T00:00:01.000000Z", "renewedAt": "2026-07-22T00:00:01.000000Z",
    "expiresAt": "2026-07-22T00:00:02.000000Z", "fence": 1,
    "clock": {"hostId": "fake-host", "bootId": "fake-boot", "monotonicSource": "linux-proc-uptime",
              "acquiredMonotonicNs": 1000000000, "expiresMonotonicNs": 2000000000},
}
value["leaseFences"]["task-1"] = 1
value["executionStarted"]["task-1"] = {"revision": 1, "occurredAt": "2026-07-22T00:00:01.000000Z"}
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
bash "$LOOP" tick --json > "$TMP_ROOT/bad-reclaimed.json"
assert_json "$TMP_ROOT/bad-reclaimed.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_json "$FAKE_STATE" "value['runnerRequests'] == [] and value['leases'] == {}"

configure mutation-transition-mismatch
set_fake mutationMode '"bad-transition-data"'
bash "$LOOP" tick --json > "$TMP_ROOT/bad-transition.json"
assert_json "$TMP_ROOT/bad-transition.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_json "$FAKE_STATE" "value['leases'] == {} and next(item for item in value['nodes'] if item['kind'] == 'task')['state'] == 'failed'"

configure mutation-renew-mismatch
set_fake runnerMode '"sleep-succeeded"'
set_fake mutationMode '"bad-renew-data"'
bash "$LOOP" tick --json > "$TMP_ROOT/bad-renew.json"
assert_json "$TMP_ROOT/bad-renew.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure mutation-renew-reshape
set_fake runnerMode '"sleep-succeeded"'
set_fake mutationMode '"bad-renew-reshape"'
bash "$LOOP" tick --json > "$TMP_ROOT/bad-renew-reshape.json"
assert_json "$TMP_ROOT/bad-renew-reshape.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure mutation-release-mismatch
set_fake mutationMode '"bad-release-data"'
bash "$LOOP" tick --json > "$TMP_ROOT/bad-release.json"
assert_json "$TMP_ROOT/bad-release.json" "value['data']['actions'][0]['releaseError']['code'] == 'MUTATION_INTERFACE_PROTOCOL'"
assert_json "$FAKE_STATE" "value['leases'] == {}"

# Scheduler overrides are test-only. Full-shape validation rejects immutable
# mismatches, duplicates, omissions, and invented status fields before claims.
configure scheduler-production-pin
export OPERATOR_LOOP_SCHEDULER="$FAKE_SCHEDULER"
unset OPERATOR_LOOP_TEST_MODE
expect_error TRUSTED_INTERFACE_UNAVAILABLE bash "$LOOP" tick --dry-run --json
export OPERATOR_LOOP_TEST_MODE=1
for scheduler_mode in runnable-mismatch runnable-duplicate candidate-omitted; do
  export FAKE_SCHEDULER_MODE="$scheduler_mode"
  expect_error INTERFACE_PROTOCOL bash "$LOOP" tick --dry-run --json
  assert_json "$FAKE_STATE" "value['graphEvents'] == []"
done
export FAKE_SCHEDULER_MODE=status-extra
expect_error INTERFACE_PROTOCOL bash "$LOOP" status --json
unset OPERATOR_LOOP_SCHEDULER FAKE_SCHEDULER_MODE

# Persistent claim races are explicit typed diagnostics, never silent zero-action success.
for conflict_code in REVISION_CONFLICT LEASE_CONFLICT FENCE_STALE RECONCILIATION_REQUIRED; do
  configure "conflict-$conflict_code"
  set_fake mutationMode "\"conflict:$conflict_code\""
  bash "$LOOP" tick --json > "$TMP_ROOT/conflict-$conflict_code.json"
  assert_json "$TMP_ROOT/conflict-$conflict_code.json" "value['data']['claimedCount'] == 0 and value['data']['diagnostics'][0]['code'] == '$conflict_code'"
done

# Snapshot, clock, mutation, scheduler, and runner interfaces are bounded while
# live. Hangs and both output floods terminate promptly without stranded leases.
export OPERATOR_LOOP_INTERFACE_TIMEOUT_SECONDS=1
export OPERATOR_LOOP_SCHEDULER_TIMEOUT_SECONDS=1
export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=1
for role in snapshot clock mutation; do
  for mode in hang stdout-over stderr-over; do
    configure "$role-$mode"
    set_fake "interfaceModes.$role" "\"$mode\""
    started="$SECONDS"
    expected=INTERFACE_TIMEOUT
    [ "$mode" = hang ] || expected=INTERFACE_LIMIT
    expect_error "$expected" bash "$LOOP" tick --json
    [ $((SECONDS - started)) -lt 5 ] || fail "$role $mode was not bounded"
    assert_json "$FAKE_STATE" "value['leases'] == {}"
  done
done

export OPERATOR_LOOP_SCHEDULER="$FAKE_SCHEDULER"
export OPERATOR_LOOP_TEST_MODE=1
for mode in hang stdout-over stderr-over; do
  configure "scheduler-$mode"
  export FAKE_SCHEDULER_MODE="$mode"
  started="$SECONDS"
  expected=INTERFACE_TIMEOUT
  [ "$mode" = hang ] || expected=INTERFACE_LIMIT
  expect_error "$expected" bash "$LOOP" tick --dry-run --json
  [ $((SECONDS - started)) -lt 5 ] || fail "scheduler $mode was not bounded"
  assert_json "$FAKE_STATE" "value['leases'] == {}"
done
unset OPERATOR_LOOP_SCHEDULER FAKE_SCHEDULER_MODE

for mode in hang stdout-over stderr-over; do
  configure "runner-$mode"
  set_fake interfaceModes.runner "\"$mode\""
  started="$SECONDS"
  bash "$LOOP" tick --json > "$TMP_ROOT/runner-$mode.json"
  [ $((SECONDS - started)) -lt 5 ] || fail "runner $mode was not bounded"
  assert_json "$TMP_ROOT/runner-$mode.json" "value['data']['actions'][0]['outcome'] == 'failed'"
  assert_json "$FAKE_STATE" "value['leases'] == {}"
  [ "$(wc -l < "$OPERATOR_DIR/loop/events.jsonl" | tr -d ' ')" -eq 1 ] || fail "runner $mode did not append exactly one event"
done

# Production process containment captures the stable child PGID. A descendant
# that ignores TERM is KILLed after the bounded grace period even if its leader
# exits first. Test mode is unset; it gates scheduler selection only.
unset OPERATOR_LOOP_TEST_MODE OPERATOR_LOOP_SCHEDULER FAKE_SCHEDULER_MODE
configure descendant-interface-timeout
set_fake interfaceModes.snapshot '"descendant-hang"'
expect_error INTERFACE_TIMEOUT bash "$LOOP" tick --json
assert_descendant_gone snapshot
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure descendant-interface-overflow
set_fake interfaceModes.clock '"descendant-stdout-over"'
expect_error INTERFACE_LIMIT bash "$LOOP" tick --json
assert_descendant_gone clock
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure descendant-runner-timeout
set_fake interfaceModes.runner '"descendant-hang"'
bash "$LOOP" tick --json > "$TMP_ROOT/descendant-runner-timeout.json"
assert_json "$TMP_ROOT/descendant-runner-timeout.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_descendant_gone runner
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure descendant-runner-overflow
set_fake interfaceModes.runner '"descendant-stdout-over"'
bash "$LOOP" tick --json > "$TMP_ROOT/descendant-runner-overflow.json"
assert_json "$TMP_ROOT/descendant-runner-overflow.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_descendant_gone runner
assert_json "$FAKE_STATE" "value['leases'] == {}"

export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=5
configure descendant-heartbeat-failure
set_fake interfaceModes.runner '"descendant-hang"'
set_fake mutationMode '"renew-error"'
bash "$LOOP" tick --json > "$TMP_ROOT/descendant-heartbeat.json"
assert_json "$TMP_ROOT/descendant-heartbeat.json" "value['data']['actions'][0]['outcome'] == 'failed'"
assert_descendant_gone runner
assert_json "$FAKE_STATE" "value['leases'] == {}"

export OPERATOR_LOOP_INTERFACE_TIMEOUT_SECONDS=2
export OPERATOR_LOOP_SCHEDULER_TIMEOUT_SECONDS=2
export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=5

# Timeout settings are validated before a graph claim.
configure invalid-timeout
export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=invalid
expect_error USAGE bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['graphEvents'] == []"
export OPERATOR_LOOP_RUN_TIMEOUT_SECONDS=5
export OPERATOR_LOOP_HEARTBEAT_SECONDS=0
expect_error USAGE bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['graphEvents'] == []"
export OPERATOR_LOOP_HEARTBEAT_SECONDS=1

# Every runner-result field is type-checked before membership or identity use.
runner_field_cases=(
  'schemaVersion:{"nested":true}'
  'runId:[]'
  'nodeId:true'
  'leaseId:null'
  'fence:[]'
  'status:{}'
  'summary:[]'
  'error:true'
)
for field_case in "${runner_field_cases[@]}"; do
  field="${field_case%%:*}"
  replacement="${field_case#*:}"
  configure "runner-field-$field"
  set_fake runnerPatch "{\"$field\":$replacement}"
  bash "$LOOP" tick --json > "$TMP_ROOT/runner-field-$field.json"
  assert_json "$TMP_ROOT/runner-field-$field.json" "value['data']['actions'][0]['outcome'] == 'failed' and value['data']['actions'][0]['runnerResult']['error']['code'] == 'RUNNER_PROTOCOL'"
  assert_json "$FAKE_STATE" "value['leases'] == {} and next(item for item in value['nodes'] if item['kind'] == 'task')['state'] == 'failed'"
  [ "$(wc -l < "$OPERATOR_DIR/loop/events.jsonl" | tr -d ' ')" -eq 1 ] || fail "runner field $field did not append exactly one event"
done

# Nonzero runner stderr is base64url evidence, including newline, ANSI/control,
# and invalid UTF-8. It cannot poison canonical event JSON.
configure runner-unsafe-stderr
set_fake runnerMode '"nonzero-unsafe-stderr"'
bash "$LOOP" tick --json > "$TMP_ROOT/unsafe-stderr.json"
python3 - "$FAKE_STATE" "$OPERATOR_DIR/loop/events.jsonl" <<'PY'
import base64, json, sys
value = json.load(open(sys.argv[1]))
event = json.loads(open(sys.argv[2]).readline())
error = event["runnerResult"]["error"]
padding = "=" * (-len(error["stderr"]) % 4)
decoded = base64.urlsafe_b64decode(error["stderr"] + padding)
assert decoded.endswith(b"line\n\x1b[31mred\x00\xff"), decoded
assert error["stderrEncoding"] == "base64url"
assert value["leases"] == {} and len(open(sys.argv[2]).readlines()) == 1
PY

# The runner receives a minimal environment; authority paths and unrelated
# process secrets are not inherited.
configure runner-minimal-environment
export OPERATOR_LOOP_UNRELATED_SECRET=must-not-reach-runner
bash "$LOOP" tick --json > "$TMP_ROOT/runner-environment.json"
unset OPERATOR_LOOP_UNRELATED_SECRET
python3 - "$FAKE_STATE" <<'PY'
import json, sys
environment = set(json.load(open(sys.argv[1]))["runnerEnvironments"][0])
assert {"LANG", "LC_ALL", "PATH"} <= environment, environment
for forbidden in ("OPERATOR_DIR", "FAKE_STATE", "OPERATOR_LOOP_SNAPSHOT_COMMAND",
                  "OPERATOR_LOOP_CLOCK_COMMAND", "OPERATOR_LOOP_MUTATION_COMMAND",
                  "OPERATOR_LOOP_UNRELATED_SECRET"):
    assert forbidden not in environment
PY

# Loop state is anchored beneath an owned real loop directory. Symlinked and
# non-regular directories/files fail with one stable IO_ERROR and never escape.
configure io-loop-symlink
outside="$TMP_ROOT/outside-loop"
mkdir -p "$outside"
ln -s "$outside" "$OPERATOR_DIR/loop"
expect_error IO_ERROR bash "$LOOP" pause --json
[ ! -e "$outside/state.json" ] || fail "loop directory symlink escaped containment"

configure io-state-symlink
mkdir -p "$OPERATOR_DIR/loop"
outside_state="$TMP_ROOT/outside-state.json"
printf '%s\n' sentinel > "$outside_state"
ln -s "$outside_state" "$OPERATOR_DIR/loop/state.json"
expect_error IO_ERROR bash "$LOOP" pause --json
[ "$(cat "$outside_state")" = sentinel ] || fail "state symlink target changed"

configure io-lease-symlink
mkdir -p "$OPERATOR_DIR/loop"
outside_lease="$TMP_ROOT/outside-lease.json"
printf '%s\n' sentinel > "$outside_lease"
ln -s "$outside_lease" "$OPERATOR_DIR/loop/lease.json"
expect_error IO_ERROR bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['leases'] == {}"
[ "$(cat "$outside_lease")" = sentinel ] || fail "lease symlink target changed"

configure io-events-symlink
mkdir -p "$OPERATOR_DIR/loop"
outside_events="$TMP_ROOT/outside-events.jsonl"
printf '%s\n' sentinel > "$outside_events"
ln -s "$outside_events" "$OPERATOR_DIR/loop/events.jsonl"
expect_error IO_ERROR bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['leases'] == {}"
[ "$(cat "$outside_events")" = sentinel ] || fail "event symlink target changed"

configure io-loop-nondirectory
printf '%s\n' not-a-directory > "$OPERATOR_DIR/loop"
expect_error IO_ERROR bash "$LOOP" pause --json

configure io-event-directory
mkdir -p "$OPERATOR_DIR/loop/events.jsonl"
expect_error IO_ERROR bash "$LOOP" tick --json
assert_json "$FAKE_STATE" "value['leases'] == {}"

configure io-permission
mkdir -p "$OPERATOR_DIR/loop"
chmod 500 "$OPERATOR_DIR/loop"
expect_error IO_ERROR bash "$LOOP" pause --json
chmod 700 "$OPERATOR_DIR/loop"

# Existing owned state is tightened to 0600 through the anchored descriptor
# before reads or appends; no event is appended while its journal is 0644.
configure io-private-state
mkdir -m 700 "$OPERATOR_DIR/loop"
printf '%s\n' '{"generation":0,"paused":false,"reason":null,"schemaVersion":"operator.loop-state/v1","updatedAt":null}' > "$OPERATOR_DIR/loop/state.json"
chmod 644 "$OPERATOR_DIR/loop/state.json"
bash "$LOOP" status --json > "$TMP_ROOT/private-state.json"
[ "$(stat -f '%Lp' "$OPERATOR_DIR/loop/state.json")" = 600 ] || fail "state.json was not tightened before read"

configure io-private-lease
mkdir -m 700 "$OPERATOR_DIR/loop"
printf '%s\n' '{"claim":null,"clock":{"bootId":"fake-boot","hostId":"fake-host","monotonicNs":10000000000,"monotonicSource":"linux-proc-uptime","schemaVersion":"operator.scheduler-clock/v1"},"maxActions":1,"pid":1,"renewedAt":"2026-07-22T00:00:00.000000Z","schemaVersion":"operator.loop-lease/v1","startedAt":"2026-07-22T00:00:00.000000Z","tickId":"manual-tick"}' > "$OPERATOR_DIR/loop/lease.json"
chmod 644 "$OPERATOR_DIR/loop/lease.json"
bash "$LOOP" status --json > "$TMP_ROOT/private-lease.json"
[ "$(stat -f '%Lp' "$OPERATOR_DIR/loop/lease.json")" = 600 ] || fail "lease.json was not tightened before read"

configure io-private-events
mkdir -m 700 "$OPERATOR_DIR/loop"
: > "$OPERATOR_DIR/loop/events.jsonl"
chmod 644 "$OPERATOR_DIR/loop/events.jsonl"
bash "$LOOP" tick --json > "$TMP_ROOT/private-events.json"
[ "$(stat -f '%Lp' "$OPERATOR_DIR/loop/events.jsonl")" = 600 ] || fail "events.jsonl was not tightened before append"
[ "$(wc -l < "$OPERATOR_DIR/loop/events.jsonl" | tr -d ' ')" -eq 1 ] || fail "private event journal did not receive exactly one event"

# Replacing lease.json with a symlink during an in-flight heartbeat stops the
# process group, fails/releases the graph work, appends one event, and reports
# stable cleanup I/O failure without touching the target.
configure io-heartbeat-symlink
set_fake runnerMode '"sleep-succeeded"'
bash "$LOOP" tick --json > "$TMP_ROOT/io-heartbeat.json" 2> "$TMP_ROOT/io-heartbeat.err" &
io_tick_pid="$!"
for _ in $(seq 1 100); do
  python3 - "$FAKE_STATE" <<'PY' && break || true
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["runnerRequests"] else 1)
PY
  sleep 0.02
done
outside_heartbeat="$TMP_ROOT/outside-heartbeat.json"
printf '%s\n' sentinel > "$outside_heartbeat"
mv "$OPERATOR_DIR/loop/lease.json" "$OPERATOR_DIR/loop/lease.saved"
ln -s "$outside_heartbeat" "$OPERATOR_DIR/loop/lease.json"
set +e
wait "$io_tick_pid"
io_status="$?"
set -e
[ "$io_status" -ne 0 ] || fail "heartbeat lease symlink did not fail"
assert_json "$TMP_ROOT/io-heartbeat.err" "value['error']['code'] == 'IO_ERROR'"
assert_json "$FAKE_STATE" "value['leases'] == {}"
[ "$(cat "$outside_heartbeat")" = sentinel ] || fail "heartbeat symlink target changed"
[ "$(wc -l < "$OPERATOR_DIR/loop/events.jsonl" | tr -d ' ')" -eq 1 ] || fail "heartbeat I/O failure did not append exactly one event"

# JSON CLI errors are exactly one parseable record, including missing config.
configure cli-errors
expect_error USAGE bash "$LOOP" invented --json
expect_error USAGE bash "$LOOP" tick --max-actions --json
expect_error USAGE bash "$LOOP" tick --max-actions nope --json
expect_error USAGE bash "$LOOP" pause --reason --json
expect_error USAGE env -u OPERATOR_DIR -u OPERATOR_CONFIG bash "$LOOP" tick --json

# A hard-killed parent can leave its runner alive. RM-0003 proves the surviving
# request carries idempotency/fence data and that recovery advances the fence;
# RM-0005 must supervise/terminate descendants and reject fence-1 effects.
configure crash-survivor
survivor_status="$(python3 - "$LOOP" "$TMP_ROOT/survivor.json" "$TMP_ROOT/survivor.err" <<'PY'
import os, subprocess, sys
with open(sys.argv[2], "wb") as output, open(sys.argv[3], "wb") as error:
    result = subprocess.run(["bash", sys.argv[1], "tick", "--json"], env=os.environ,
                            stdout=output, stderr=error, check=False)
print(result.returncode)
PY
)"
[ "$survivor_status" -ne 0 ] || fail "surviving-runner scenario did not kill the loop parent"
SURVIVOR_PID="$(python3 - "$FAKE_STATE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["survivorPid"])
PY
)"
kill -0 "$SURVIVOR_PID" 2>/dev/null || fail "runner did not survive the killed parent"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["clockNs"] = value["leases"]["task-1"]["clock"]["expiresMonotonicNs"]
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
bash "$LOOP" tick --json > "$TMP_ROOT/survivor-retry.json"
assert_json "$TMP_ROOT/survivor-retry.json" "value['data']['actions'][0]['fence'] == 2"
kill -0 "$SURVIVOR_PID" 2>/dev/null || fail "test no longer demonstrates host-owned descendant containment"
kill -TERM -- "-$SURVIVOR_PID" 2>/dev/null || true
SURVIVOR_PID=""

# Status consumes the same trusted snapshot+clock scheduler boundary.
configure success
bash "$LOOP" status --json > "$TMP_ROOT/status.json"
assert_json "$TMP_ROOT/status.json" "value['data']['schemaVersion'] == 'operator.loop-status/v1' and value['data']['scheduler']['schemaVersion'] == 'operator.scheduler-status/v1' and value['data']['scheduler']['capacity'] == 1"

printf 'operator v5 loop smoke passed\n'
