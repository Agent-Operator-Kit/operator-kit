#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_GRAPH_SCRIPT="$KIT_ROOT/scripts/operator-graph.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-control-graph.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Non-installed test broker: proof private keys are generated ephemerally outside
# OPERATOR_DIR and are held by this broker, never by the graph runtime.
PROOF_KEY_DIR="$TMP_ROOT/proof-keys"
mkdir -p "$PROOF_KEY_DIR"
for binding in operator system human lane-a lane-a-test lane-a-recovery lane-b host fake-human human-overpowered subagent long-scope; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 \
    -out "$PROOF_KEY_DIR/$binding.pem" >/dev/null 2>&1
done

PROOF_RUNNER="$TMP_ROOT/proof-runner.py"
cat > "$PROOF_RUNNER" <<'PY'
#!/usr/bin/env python3
import base64, copy, json, os, socket, subprocess, sys, threading

key_path = sys.argv[1]
command = sys.argv[2:]
parent, child = socket.socketpair()

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()

def broker():
    with parent:
        stream = parent.makefile("rwb", buffering=0)
        expected_phase = "authorize"
        session_key = None
        while True:
            line = stream.readline()
            if not line:
                return
            challenge = json.loads(line)
            assert set(challenge) == {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}
            assert challenge["schemaVersion"] == "operator.proof-challenge/v1"
            assert challenge["operation"] == "sign"
            phase = challenge["phase"]
            assert phase == expected_phase
            assert phase in {"authorize", "event"}
            if session_key is None:
                session_key = challenge["proofKeyId"]
            assert challenge["proofKeyId"] == session_key
            payload = challenge["payload"]
            assert payload["schemaVersion"] == (
                "operator.mutation-proof-request/v1" if phase == "authorize"
                else "operator.mutation-event-proof/v1"
            )
            signed_value = copy.deepcopy(payload)
            alteration = os.environ.get("OPERATOR_GRAPH_SMOKE_ALTER_AUTH")
            if phase == "authorize" and alteration == "request":
                signed_value["requestId"] = "altered-by-test-broker"
            elif phase == "authorize" and alteration == "intent":
                signed_value["intent"] = {"altered": True}
            elif phase == "authorize" and alteration == "cas":
                signed_value["expectedRevision"] = 999999
            elif phase == "authorize" and alteration == "generation":
                signed_value["bindingGeneration"] += 1
            if phase == "event" and "OPERATOR_GRAPH_SMOKE_ALTER_EVENT" in os.environ:
                signed_value["tampered"] = True
            signing_payload = canonical(signed_value)
            signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                                    input=signing_payload, stdout=subprocess.PIPE, check=True).stdout
            if phase == "authorize" and alteration == "proof":
                signed = bytes([signed[0] ^ 1]) + signed[1:]
            response = {
                "schemaVersion": "operator.proof-response/v1", "phase": phase,
                "proofKeyId": challenge["proofKeyId"],
                "signature": base64.urlsafe_b64encode(signed).decode().rstrip("="),
            }
            mode = os.environ.get("OPERATOR_GRAPH_SMOKE_RESPONSE_MODE")
            if mode == "response-as-challenge":
                response = challenge
            elif mode == "wrong-version":
                response["schemaVersion"] = "operator.proof-challenge/v1"
            elif mode == "phase-reorder" and phase == "authorize":
                response["phase"] = "event"
            elif mode == "phase-reuse" and phase == "event":
                response["phase"] = "authorize"
            elif mode == "extra-field":
                response["extra"] = True
            elif mode == "key-change" and phase == "event":
                response["proofKeyId"] = challenge["proofKeyId"] + "-changed"
            stream.write(canonical(response))
            expected_phase = "event" if phase == "authorize" else "complete"
            if expected_phase == "complete":
                return

thread = threading.Thread(target=broker, daemon=True)
thread.start()
completed = subprocess.run(command + ["--proof-fd", str(child.fileno())], pass_fds=(child.fileno(),))
child.close()
thread.join(timeout=2)
raise SystemExit(completed.returncode)
PY
chmod +x "$PROOF_RUNNER"

SIGNED_EVENT_FORGER="$TMP_ROOT/signed-event-forger.py"
cat > "$SIGNED_EVENT_FORGER" <<'PY'
#!/usr/bin/env python3
import base64, datetime as dt, hashlib, json, subprocess, sys

journal_path, mutation, key_path = sys.argv[1:]

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()

def sign(value):
    raw = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=canonical(value), stdout=subprocess.PIPE, check=True).stdout
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))

def format_time(value):
    return value.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")

lines = open(journal_path, encoding="utf-8").readlines()
events = [json.loads(line) for line in lines]
if mutation == "renewal-reshape":
    index = next(index for index, event in enumerate(events) if event["type"] == "lease.renewed")
else:
    index = next(index for index, event in enumerate(events) if event["type"] == "lease.acquired")
event = events[index]

if mutation == "terminal-acquire":
    for lease in (event["data"]["lease"], event["result"]["data"]["lease"]):
        lease["nodeId"] = "complete-task"
    event["intent"]["nodeId"] = "complete-task"
elif mutation == "invalid-ttl":
    ttl = 86401
    event["intent"]["ttlSeconds"] = ttl
    for lease in (event["data"]["lease"], event["result"]["data"]["lease"]):
        lease["expiresAt"] = format_time(timestamp(event["occurredAt"]) + dt.timedelta(seconds=ttl))
        lease["clock"]["expiresMonotonicNs"] = event["clock"]["monotonicNs"] + ttl * 1_000_000_000
elif mutation == "generated-id":
    event["intent"]["leaseId"] = None
elif mutation == "holder-divergence":
    for lease in (event["data"]["lease"], event["result"]["data"]["lease"]):
        lease["holder"]["actorId"] = "forged-holder"
elif mutation == "renewal-reshape":
    for lease in (event["data"]["lease"], event["result"]["data"]["lease"]):
        lease["expiresAt"] = format_time(timestamp(lease["expiresAt"]) + dt.timedelta(seconds=1))
else:
    raise AssertionError(mutation)

actor = event["actor"]
authorization = {
    "schemaVersion": "operator.mutation-proof-request/v1", "command": event["result"]["command"],
    "requestId": event["requestId"], "bindingId": actor["bindingId"],
    "bindingGeneration": actor["bindingGeneration"], "bindingHash": actor["bindingHash"],
    "intent": event["intent"], "expectedRevision": event["expectedRevision"],
}
event["requestFingerprint"] = "sha256:" + hashlib.sha256(canonical(authorization)).hexdigest()
event["proof"]["authorizationSignature"] = sign(authorization)
unsigned = {key: value for key, value in event.items() if key != "proof"}
event_payload = {"schemaVersion": "operator.mutation-event-proof/v1", "event": unsigned}
event["proof"]["eventSignature"] = sign(event_payload)
lines[index] = canonical(event).decode()
with open(journal_path, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
PY
chmod +x "$SIGNED_EVENT_FORGER"

GRAPH_SCRIPT="$TMP_ROOT/operator-graph-proof.sh"
cat > "$GRAPH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
binding=""
previous=""
for argument in "\$@"; do
  if [ "\$previous" = "--actor-binding" ]; then binding="\$argument"; break; fi
  previous="\$argument"
done
if [ -z "\$binding" ]; then exec bash "$REAL_GRAPH_SCRIPT" "\$@"; fi
proof_binding="\${OPERATOR_GRAPH_SMOKE_PROOF_AS:-\$binding}"
exec python3 "$PROOF_RUNNER" "$PROOF_KEY_DIR/\$proof_binding.pem" bash "$REAL_GRAPH_SCRIPT" "\$@"
EOF
chmod +x "$GRAPH_SCRIPT"

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
  mkdir -p "$target/authority"
  cp "$source/graph/definition.json" "$target/graph/definition.json"
  cp "$source/graph/projection.json" "$target/graph/projection.json"
  cp "$source/graph/events.jsonl" "$target/graph/events.jsonl"
  cp "$source/authority/control-graph-public-key.json" "$target/authority/control-graph-public-key.json"
}

write_bindings() {
  local operator_dir="$1"
  mkdir -p "$operator_dir/graph/bindings"
  python3 - "$operator_dir" "$PROOF_KEY_DIR" <<'PY'
import base64, datetime as dt, hashlib, json, os, socket, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
proof_key_dir = Path(sys.argv[2])
n = int("db69e0f76bb58ac09964d8a1e12d4a57a25e7165cb7cf59a95a4863fa8a297df2e10b3de56bcdaae20df6461c017b53a0b95025d93ce2915fc18b887c73628f1b6fe3106de12d788f498f3daf5d8087fe48080f501df5c36b5e7e409f5f95ce13019807cb7bb2f7b422a5284949a4c284c797a6479a97638031dcf39398c8067", 16)
d = int("7c670dbc7aff558a59ee89bd4ed4c4ffe6f9b145cc182f90d423925269a4b6833db50ea6937b4469d20d96f6ad5943d1835b9b19bf81f65d96afd580767cc8bd26da0611cca73282da9402d58be9c1b737e2ec88e49b57132e978e5b34ac5d93b5acbde645ef01be52613c115a18cae32180c452f46c9fa35f490e5904795641", 16)
width = (n.bit_length() + 7) // 8

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()

def sign(payload):
    digest = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(canonical(payload)).digest()
    encoded = b"\x00\x01" + b"\xff" * (width - len(digest) - 3) + b"\x00" + digest
    raw = pow(int.from_bytes(encoded, "big"), d, n).to_bytes(width, "big")
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

authority = {
    "schemaVersion": "operator.authority-key/v1", "projectId": "smoke-project",
    "graphId": "adversarial-smoke", "keyId": "smoke-root-1", "canonicalHostId": socket.gethostname(),
    "algorithm": "RS256", "publicKey": {"n": format(n, "x"), "e": 65537},
}

(root / "authority").mkdir(parents=True, exist_ok=True)
(root / "authority" / "control-graph-public-key.json").write_bytes(canonical(authority))
bindings = {
    "operator": ({"type": "operator", "id": "control"},
                 ["graph-init", "graph-replace", "lease-resolve", "replay-repair", "sweep", "transition"], []),
    "system": ({"type": "system", "id": "heartbeat"},
               ["graph-init", "graph-replace", "lease-resolve", "replay-repair", "sweep", "transition"], []),
    "human": ({"type": "human", "id": "authorized-human"}, ["gate-decision", "lease-resolve"], []),
    "lane-a": ({"type": "lane", "id": "worker-a", "laneNodeId": "lane-a"},
               ["lease", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
    "lane-a-test": ({"type": "lane", "id": "worker-a-test", "laneNodeId": "lane-a"},
                    ["lease", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
    "lane-a-recovery": ({"type": "lane", "id": "worker-a-recovery", "laneNodeId": "lane-a"},
                        ["lease", "transition"], [{"scope": "lane:a", "laneNodeId": "lane-a"}]),
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
    modulus_output = subprocess.check_output(
        ["openssl", "rsa", "-in", str(proof_key_dir / f"{binding_id}.pem"), "-noout", "-modulus"],
        text=True, stderr=subprocess.DEVNULL,
    ).strip()
    proof_modulus = modulus_output.split("=", 1)[1].lower()
    payload = {
        "schemaVersion": "operator.actor-binding/v1",
        "bindingId": binding_id,
        "generation": 1,
        "projectId": "smoke-project",
        "graphId": "adversarial-smoke",
        "issuedAt": "2020-01-01T00:00:00Z",
        "expiresAt": "2099-01-01T00:00:00Z",
        "subject": subject,
        "capabilities": sorted(capabilities),
        "leaseScopes": scopes,
        "proofKey": {"keyId": f"proof-{binding_id}-1", "algorithm": "RS256",
                     "publicKey": {"n": proof_modulus, "e": 65537}},
    }
    payload["signature"] = {"keyId": "smoke-root-1", "algorithm": "RS256", "value": sign(payload)}
    path = root / "graph" / "bindings" / f"{binding_id}.json"
    path.write_bytes(canonical(payload))
PY
}

resign_binding() {
  local path="$1"
  local generation="$2"
  local project_id="${3:--}"
  local graph_id="${4:--}"
  local expires_at="${5:--}"
  local issued_at="${6:--}"
  python3 - "$path" "$generation" "$project_id" "$graph_id" "$expires_at" "$issued_at" <<'PY'
import base64, hashlib, json, sys
path, generation, project_id, graph_id, expires_at, issued_at = sys.argv[1:]
n = int("db69e0f76bb58ac09964d8a1e12d4a57a25e7165cb7cf59a95a4863fa8a297df2e10b3de56bcdaae20df6461c017b53a0b95025d93ce2915fc18b887c73628f1b6fe3106de12d788f498f3daf5d8087fe48080f501df5c36b5e7e409f5f95ce13019807cb7bb2f7b422a5284949a4c284c797a6479a97638031dcf39398c8067", 16)
d = int("7c670dbc7aff558a59ee89bd4ed4c4ffe6f9b145cc182f90d423925269a4b6833db50ea6937b4469d20d96f6ad5943d1835b9b19bf81f65d96afd580767cc8bd26da0611cca73282da9402d58be9c1b737e2ec88e49b57132e978e5b34ac5d93b5acbde645ef01be52613c115a18cae32180c452f46c9fa35f490e5904795641", 16)
value = json.load(open(path, encoding="utf-8"))
value["generation"] = int(generation)
if project_id != "-": value["projectId"] = project_id
if graph_id != "-": value["graphId"] = graph_id
if expires_at != "-": value["expiresAt"] = expires_at
if issued_at != "-": value["issuedAt"] = issued_at
value["subject"]["id"] += f"-g{generation}"
payload = {key: value[key] for key in ("schemaVersion", "bindingId", "generation", "projectId", "graphId", "issuedAt", "expiresAt", "subject", "capabilities", "leaseScopes", "proofKey")}
canonical = (json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
width = (n.bit_length() + 7) // 8
digest = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(canonical).digest()
encoded = b"\x00\x01" + b"\xff" * (width - len(digest) - 3) + b"\x00" + digest
signature = pow(int.from_bytes(encoded, "big"), d, n).to_bytes(width, "big")
value["signature"] = {"keyId": "smoke-root-1", "algorithm": "RS256", "value": base64.urlsafe_b64encode(signature).decode().rstrip("=")}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
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
    {"id": "cancel-task", "kind": "task", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
    {"id": "complete-task", "kind": "task", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
    {"id": "resolve-dependency", "kind": "task", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
    {"id": "resolve-validation", "kind": "integration", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
    {"id": "resolve-gated", "kind": "integration", "metadata": {"execution": {"idempotent": false, "reclaimable": false}}},
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
    {"kind": "contains", "from": "feature", "to": "cancel-task"},
    {"kind": "contains", "from": "feature", "to": "complete-task"},
    {"kind": "contains", "from": "feature", "to": "resolve-dependency"},
    {"kind": "contains", "from": "feature", "to": "resolve-validation"},
    {"kind": "contains", "from": "feature", "to": "resolve-gated"},
    {"kind": "contains", "from": "feature", "to": "safe-task"},
    {"kind": "assigned-to", "from": "dependency", "to": "lane-a"},
    {"kind": "assigned-to", "from": "main", "to": "lane-a"},
    {"kind": "assigned-to", "from": "validation", "to": "lane-a"},
    {"kind": "assigned-to", "from": "integration", "to": "lane-a"},
    {"kind": "assigned-to", "from": "integration-no-gate", "to": "lane-a"},
    {"kind": "assigned-to", "from": "host-task", "to": "lane-a"},
    {"kind": "assigned-to", "from": "side-effect", "to": "lane-a"},
    {"kind": "assigned-to", "from": "cancel-task", "to": "lane-a"},
    {"kind": "assigned-to", "from": "complete-task", "to": "lane-a"},
    {"kind": "assigned-to", "from": "resolve-dependency", "to": "lane-a"},
    {"kind": "assigned-to", "from": "resolve-validation", "to": "lane-a"},
    {"kind": "assigned-to", "from": "resolve-gated", "to": "lane-a"},
    {"kind": "assigned-to", "from": "safe-task", "to": "lane-a"},
    {"kind": "depends-on", "from": "main", "to": "dependency"},
    {"kind": "validated-by", "from": "main", "to": "validation"},
    {"kind": "depends-on", "from": "resolve-dependency", "to": "dependency"},
    {"kind": "validated-by", "from": "resolve-validation", "to": "validation"},
    {"kind": "gated-by", "from": "resolve-validation", "to": "gate"},
    {"kind": "gated-by", "from": "resolve-gated", "to": "gate"},
    {"kind": "gated-by", "from": "main", "to": "gate"},
    {"kind": "gated-by", "from": "integration", "to": "gate-reject"},
    {"kind": "integrates-into", "from": "integration", "to": "feature"},
    {"kind": "integrates-into", "from": "integration-no-gate", "to": "feature"},
    {"kind": "integrates-into", "from": "resolve-validation", "to": "feature"},
    {"kind": "integrates-into", "from": "resolve-gated", "to": "feature"}
  ]
}
JSON

# Version, type, reference, endpoint, cycle, number, control, size, and depth hardening.
INVALID_DIR="$TMP_ROOT/invalid-operator"
write_bindings "$INVALID_DIR"
UNKNOWN="$TMP_ROOT/unknown.json"
sed 's/operator.control-graph\/v1/operator.control-graph\/v999/' "$DEFINITION" > "$UNKNOWN"
expect_error 4 UNKNOWN_VERSION env OPERATOR_DIR="$INVALID_DIR" bash "$GRAPH_SCRIPT" validate "$UNKNOWN"

for mutation in bad-reference bad-kind bad-endpoint bad-cycle bad-gate-metadata bad-initial-state narrowed-integration-gate; do
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
elif kind == "bad-gate-metadata":
    edge = next(item for item in value["edges"] if item["kind"] == "gated-by")
    edge["metadata"] = {"protectedTransitions": ["not-a-state"]}
elif kind == "bad-initial-state":
    next(item for item in value["nodes"] if item["id"] == "main")["initialState"] = "active"
else:
    edge = next(item for item in value["edges"] if item["kind"] == "gated-by" and item["from"] == "integration")
    edge["metadata"] = {"protectedTransitions": ["active"]}
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

# Event-phase broker records support the full event bound rather than the
# 64-KiB binding limit. A real schema-valid init above 64 KiB succeeds.
LARGE_DEFINITION="$TMP_ROOT/large-definition.json"
python3 - "$LARGE_DEFINITION" <<'PY'
import json, sys
value = {
    "schemaVersion": "operator.control-graph/v1", "graphId": "adversarial-smoke",
    "nodes": [
        {"id": f"large-{index:04d}", "kind": "task", "title": "x" * 300}
        for index in range(400)
    ],
    "edges": [],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
[ "$(wc -c < "$LARGE_DEFINITION" | tr -d ' ')" -gt 65536 ] || fail "large definition did not cross 64 KiB"
LARGE_DIR="$TMP_ROOT/large-operator"
write_bindings "$LARGE_DIR"
env OPERATOR_DIR="$LARGE_DIR" bash "$GRAPH_SCRIPT" init --definition "$LARGE_DEFINITION" \
  --request-id large-init --actor-binding operator > /dev/null
[ "$(wc -c < "$LARGE_DIR/graph/events.jsonl" | tr -d ' ')" -gt 65536 ] || fail "large event did not cross 64 KiB"
env OPERATOR_DIR="$LARGE_DIR" bash "$GRAPH_SCRIPT" replay check > /dev/null

# The encoded event challenge is accepted at its explicit hard boundary and
# rejected one byte over it before any socket write.
PYTHONPATH="$KIT_ROOT/scripts" python3 - <<'PY'
import json
import operator_graph as graph

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()

class FakeSocket:
    def __init__(self, response):
        self.response = response
        self.sent = b""
    def sendall(self, value):
        self.sent += value
    def recv(self, size):
        value, self.response = self.response[:size], self.response[size:]
        return value

graph.verify_rsa_signature = lambda *args, **kwargs: None
key = {"keyId": "boundary-proof", "publicKey": {"n": "f" * 256, "e": 65537}}
response = canonical({"schemaVersion": graph.PROOF_RESPONSE_VERSION, "phase": "event",
                      "proofKeyId": key["keyId"], "signature": "A"})
base_payload = {"blob": ""}
base_challenge = {"schemaVersion": graph.PROOF_CHALLENGE_VERSION, "operation": "sign", "phase": "event",
                  "proofKeyId": key["keyId"], "payload": base_payload}
padding = graph.MAX_PROOF_EVENT_CHALLENGE_BYTES - len(canonical(base_challenge))
assert padding > 0
channel = graph.ProofChannel.__new__(graph.ProofChannel)
channel.socket = FakeSocket(response)
channel.next_phase = "event"
channel.proof_key_id = key["keyId"]
assert channel.sign("event", {"blob": "x" * padding}, key) == "A"
assert len(channel.socket.sent) == graph.MAX_PROOF_EVENT_CHALLENGE_BYTES

channel = graph.ProofChannel.__new__(graph.ProofChannel)
channel.socket = FakeSocket(response)
channel.next_phase = "event"
channel.proof_key_id = key["keyId"]
try:
    channel.sign("event", {"blob": "x" * (padding + 1)}, key)
    raise AssertionError("over-bound event challenge was accepted")
except graph.GraphError as error:
    assert error.code == "AUTHORITY_DENIED", error.code
    assert error.details["actualBytes"] == graph.MAX_PROOF_EVENT_CHALLENGE_BYTES + 1
    assert channel.socket.sent == b""
PY

MAIN_DIR="$TMP_ROOT/main-operator"
write_bindings "$MAIN_DIR"
mkdir -p "$MAIN_DIR/roadmap"
printf 'roadmap-sentinel\n' > "$MAIN_DIR/roadmap/sentinel.txt"
ROADMAP_BEFORE="$(shasum -a 256 "$MAIN_DIR/roadmap/sentinel.txt")"

env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id init-main --actor-binding operator > "$TMP_ROOT/init.json"

# A readable signed binding is not a credential: every mutation requires proof
# from the bound private key, and every canonical request/event field is covered.
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$REAL_GRAPH_SCRIPT" init \
  --definition "$DEFINITION" --request-id readable-binding-only --actor-binding operator
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" bash "$REAL_GRAPH_SCRIPT" gate decide gate approved \
  --request-id readable-human-binding-only --actor-binding human
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_PROOF_AS=lane-a \
  bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" --request-id lane-proof-for-operator --actor-binding operator
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_PROOF_AS=lane-a \
  bash "$GRAPH_SCRIPT" gate decide gate approved --request-id lane-proof-for-human --actor-binding human
for altered in request intent cas generation proof; do
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_ALTER_AUTH="$altered" \
    bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" --request-id "altered-$altered" --actor-binding operator
done
EVENT_COUNT_BEFORE_FAILED_PROOF="$(wc -l < "$MAIN_DIR/graph/events.jsonl" | tr -d ' ')"
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_ALTER_EVENT=1 \
  bash "$GRAPH_SCRIPT" transition feature active --request-id altered-event-proof --actor-binding operator
[ "$(wc -l < "$MAIN_DIR/graph/events.jsonl" | tr -d ' ')" = "$EVENT_COUNT_BEFORE_FAILED_PROOF" ] || \
  fail "failed event proof appended a journal record"

# Challenge and response versions/shapes are distinct; one socket is strictly
# authorize-then-event with one fixed host-selected proof key.
for mode in response-as-challenge wrong-version phase-reorder extra-field; do
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_RESPONSE_MODE="$mode" \
    bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" --request-id "wire-$mode" --actor-binding operator
done
for mode in phase-reuse key-change; do
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_SMOKE_RESPONSE_MODE="$mode" \
    bash "$GRAPH_SCRIPT" transition feature active --request-id "wire-$mode" --actor-binding operator
done
[ "$(wc -l < "$MAIN_DIR/graph/events.jsonl" | tr -d ' ')" = "$EVENT_COUNT_BEFORE_FAILED_PROOF" ] || \
  fail "invalid proof wire session appended a journal record"

# Signed capability documents fail closed when unsigned, altered, expired, or scoped elsewhere.
for authority_case in unsigned altered expired wrong-project wrong-graph wrong-host wrong-key; do
  authority_dir="$TMP_ROOT/authority-$authority_case"
  write_bindings "$authority_dir"
  binding_path="$authority_dir/graph/bindings/operator.json"
  if [ "$authority_case" = "unsigned" ]; then
    python3 - "$binding_path" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")); value.pop("signature")
json.dump(value, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
  elif [ "$authority_case" = "altered" ]; then
    python3 - "$binding_path" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")); value["subject"]["id"] = "altered"
json.dump(value, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
  elif [ "$authority_case" = "expired" ]; then
    resign_binding "$binding_path" 1 - - 2021-01-01T00:00:00Z
  elif [ "$authority_case" = "wrong-project" ]; then
    resign_binding "$binding_path" 1 another-project
  elif [ "$authority_case" = "wrong-graph" ]; then
    resign_binding "$binding_path" 1 - another-graph
  elif [ "$authority_case" = "wrong-host" ]; then
    python3 - "$authority_dir/authority/control-graph-public-key.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")); value["canonicalHostId"] = "foreign-clock-host"
json.dump(value, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
  else
    python3 - "$authority_dir/authority/control-graph-public-key.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")); value["publicKey"]["n"] = "f" + value["publicKey"]["n"][1:]
json.dump(value, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
  fi
  expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$authority_dir" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
    --request-id "authority-$authority_case" --actor-binding operator
done

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
expect_error 2 USAGE env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id fake-human-label --actor-binding fake-human --actor-type human --actor-id human
expect_error 2 USAGE env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" gate decide gate approved \
  --request-id raw-human-label --actor-type human --actor-id human
for former_flag in \
  '--test-only-now=2099-01-01T00:00:00Z' \
  '--test-only-fault=after-event' \
  '--test-only-unsafe-actor-flags' \
  '--actor-type=operator' \
  '--actor-id=forged' \
  '--test-only-capability=graph-replace' \
  '--test-only-lane-node-id=lane-a' \
  '--test-only-host-runner-id=host-a' \
  '--test-only-lease-scope=lane:a=lane-a'; do
  expect_error 2 USAGE env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" transition goal active \
    --request-id "removed-${former_flag%%=*}" --actor-binding operator "$former_flag"
done
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$MAIN_DIR" OPERATOR_GRAPH_TESTING=1 \
  OPERATOR_GRAPH_ACTOR_TYPE=operator OPERATOR_GRAPH_ACTOR_ID=forged OPERATOR_GRAPH_CAPABILITIES=graph-init \
  bash "$GRAPH_SCRIPT" transition goal active --request-id env-forgery
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
assert data["schemaVersion"] == "operator.control-snapshot/v1"
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

# First lease freezes execution identity even in pending; completed identity and node IDs are also immutable.
python3 - "$MAIN_DIR/graph/definition.json" "$TMP_ROOT/rewrite-history.json" "$TMP_ROOT/remove-node.json" "$TMP_ROOT/rewrite-edge.json" "$TMP_ROOT/rewrite-leased.json" <<'PY'
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
value = json.load(open(sys.argv[1], encoding="utf-8"))
next(node for node in value["nodes"] if node["id"] == "host-task")["title"] = "rewritten after first lease"
json.dump(value, open(sys.argv[5], "w", encoding="utf-8"))
PY
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/rewrite-history.json" --request-id rewrite-history --actor-binding operator
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/remove-node.json" --request-id remove-history --actor-binding operator
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/rewrite-edge.json" --request-id rewrite-edge --actor-binding operator
expect_error 5 INVALID_GRAPH env OPERATOR_DIR="$MAIN_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/rewrite-leased.json" --request-id rewrite-leased --actor-binding operator

# Crash safety: the test harness mutates files directly; no fault path exists in the shipped CLI.
CRASH_DIR="$TMP_ROOT/crash-operator"
write_bindings "$CRASH_DIR"
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id crash-init --actor-binding operator > /dev/null
python3 - "$CRASH_DIR/graph/events.jsonl" <<'PY'
import sys
with open(sys.argv[1], "ab") as handle:
    handle.write(b'{"incomplete":"tail"')
PY
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" transition feature active \
  --request-id partial-tail --actor-binding operator > "$TMP_ROOT/partial-retry.json"
cp "$CRASH_DIR/graph/definition.json" "$TMP_ROOT/pre-event-definition.json"
cp "$CRASH_DIR/graph/projection.json" "$TMP_ROOT/pre-event-projection.json"
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" transition feature blocked \
  --request-id after-event --actor-binding operator > "$TMP_ROOT/after-event-original.json"
cp "$TMP_ROOT/pre-event-definition.json" "$CRASH_DIR/graph/definition.json"
cp "$TMP_ROOT/pre-event-projection.json" "$CRASH_DIR/graph/projection.json"
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
cp "$CRASH_DIR/graph/projection.json" "$TMP_ROOT/pre-replace-projection.json"
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" replace-definition \
  "$TMP_ROOT/crash-replacement.json" --request-id after-definition --actor-binding operator > /dev/null
cp "$TMP_ROOT/pre-replace-projection.json" "$CRASH_DIR/graph/projection.json"
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" replace-definition "$TMP_ROOT/crash-replacement.json" \
  --request-id after-definition --actor-binding operator > /dev/null
env OPERATOR_DIR="$CRASH_DIR" bash "$GRAPH_SCRIPT" replay check > /dev/null
python3 - "$CRASH_DIR/graph/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [event["sequence"] for event in events] == list(range(1, len(events) + 1))
assert len({event["requestId"] for event in events}) == len(events)
PY

# Journal preflight admits the exact boundary, rejects one byte over before append, and trims an over-boundary partial tail first.
BOUNDARY_DIR="$TMP_ROOT/boundary-operator"
write_bindings "$BOUNDARY_DIR"
env OPERATOR_DIR="$BOUNDARY_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id boundary-init --actor-binding operator > /dev/null
PYTHONPATH="$KIT_ROOT/scripts" python3 - "$BOUNDARY_DIR" "$TMP_ROOT" "$PROOF_KEY_DIR/operator.pem" <<'PY'
import base64, contextlib, datetime as dt, io, os, shutil, subprocess, sys, uuid
from pathlib import Path
import operator_graph as graph

source, root, proof_key = map(Path, sys.argv[1:])
events = graph.read_events(source / "graph" / "events.jsonl")
fixed_now = graph.parse_time(events[-1]["occurredAt"]) + dt.timedelta(milliseconds=100)
fixed_mono = events[-1]["clock"]["monotonicNs"] + 100_000_000
graph.utc_now = lambda: fixed_now
graph.host_monotonic_sample = lambda: (events[-1]["clock"]["monotonicSource"], fixed_mono)
graph.uuid.uuid4 = lambda: uuid.UUID("11111111-1111-4111-8111-111111111111")
graph.print_json = lambda value, stream=None: None

class TestProofChannel:
    def __init__(self, descriptor):
        pass
    def sign(self, phase, payload, proof_key_value):
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(proof_key)],
                                input=graph.canonical_bytes(payload), stdout=subprocess.PIPE, check=True).stdout
        return base64.urlsafe_b64encode(signed).decode().rstrip("=")
    def close(self):
        pass
graph.ProofChannel = TestProofChannel

def clone(name):
    target = root / name
    target.mkdir()
    shutil.copytree(source / "graph", target / "graph")
    shutil.copytree(source / "authority", target / "authority")
    return target

def invoke(target):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return graph.main(["--operator-dir", str(target), "transition", "feature", "active",
                           "--request-id", "boundary-event", "--actor-binding", "operator"])

calibrate = clone("boundary-calibrate")
base_size = (calibrate / "graph" / "events.jsonl").stat().st_size
assert invoke(calibrate) == 0
event_size = (calibrate / "graph" / "events.jsonl").stat().st_size - base_size
assert event_size > 0

exact = clone("boundary-exact")
graph.MAX_JOURNAL_BYTES = base_size + event_size
assert invoke(exact) == 0
assert (exact / "graph" / "events.jsonl").stat().st_size == graph.MAX_JOURNAL_BYTES

over = clone("boundary-over")
graph.MAX_JOURNAL_BYTES = base_size + event_size - 1
assert invoke(over) == graph.EXIT_CODES["JOURNAL_FULL"]
assert (over / "graph" / "events.jsonl").stat().st_size == base_size

partial = clone("boundary-partial")
with open(partial / "graph" / "events.jsonl", "ab") as handle:
    handle.write(b'{"partial-tail"')
graph.MAX_JOURNAL_BYTES = base_size + event_size
assert invoke(partial) == 0
assert (partial / "graph" / "events.jsonl").stat().st_size == graph.MAX_JOURNAL_BYTES
PY

# Trusted time, unsafe expiry reconciliation, safe reclaim, and fence tombstones.
TIME_DIR="$TMP_ROOT/time-operator"
write_bindings "$TIME_DIR"
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id time-init --actor-binding operator > /dev/null
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id wall-jump-lease --holder-scope lane:a --ttl-seconds 60 --request-id wall-jump-lease --actor-binding lane-a-test > /dev/null
PYTHONPATH="$KIT_ROOT/scripts" python3 - "$TIME_DIR" <<'PY'
import datetime as dt, json, subprocess, sys
from pathlib import Path
import operator_graph as graph

root = Path(sys.argv[1])
events = graph.read_events(root / "graph" / "events.jsonl")
lease = json.load(open(root / "graph" / "projection.json", encoding="utf-8"))["leases"]["host-task"]
previous = events[-1]
original_sample = graph.host_monotonic_sample
graph.utc_now = lambda: graph.parse_time(previous["occurredAt"]) + dt.timedelta(seconds=3600)
graph.host_monotonic_sample = lambda: (
    previous["clock"]["monotonicSource"], previous["clock"]["monotonicNs"] + 1_000_000_000,
)
try:
    graph.transaction_time(events)
    raise AssertionError("one-hour wall-clock jump was accepted")
except graph.GraphError as error:
    assert error.code == "CLOCK_SKEW", error.code
clock = {"hostId": graph.HOST_ID, "bootId": graph.BOOT_ID,
         "monotonicSource": previous["clock"]["monotonicSource"],
         "monotonicNs": previous["clock"]["monotonicNs"] + 1_000_000_000}
assert graph.lease_clock_expired(lease, clock) is False

if sys.platform == "darwin":
    code = "import operator_graph as g; print(g.host_monotonic_sample()[0], g.host_monotonic_sample()[1])"
    first = subprocess.check_output([sys.executable, "-c", code], text=True).split()
    second = subprocess.check_output([sys.executable, "-c", code], text=True).split()
    assert first[0] == second[0] == "macos-mach-continuous"
    assert int(second[1]) >= int(first[1]) > 1_000_000_000
original_platform = sys.platform
try:
    sys.platform = "unsupported-test-platform"
    try:
        original_sample()
        raise AssertionError("unsupported persisted clock fell back")
    except graph.GraphError as error:
        assert error.code == "CLOCK_UNAVAILABLE", error.code
finally:
    sys.platform = original_platform
PY
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve host-task retry \
  --lease-id wall-jump-lease --fence 1 --reason binding-rotated --request-id false-binding-rotation --actor-binding operator
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve host-task retry \
  --lease-id wall-jump-lease --fence 1 --reason clock-recovery --request-id false-clock-recovery --actor-binding operator
expect_error 2 USAGE env OPERATOR_DIR="$TIME_DIR" OPERATOR_GRAPH_TESTING=1 bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id future-theft --holder-scope lane:a --request-id future-theft --actor-binding lane-a --test-only-now 2099-01-01T00:00:00Z
for pair in 'cancel-task cancel-1' 'complete-task complete-1' 'safe-task safe-1' \
            'resolve-dependency resolve-dependency-1' 'resolve-validation resolve-validation-1' 'resolve-gated resolve-gated-1' \
            'side-effect side-1'; do
  set -- $pair
  env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire "$1" \
    --lease-id "$2" --holder-scope lane:a --ttl-seconds 1 --request-id "$2" --actor-binding lane-a-test > /dev/null
done
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" transition side-effect ready \
  --lease-id side-1 --fence 1 --request-id side-ready --actor-binding lane-a-test > /dev/null
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" transition side-effect active \
  --lease-id side-1 --fence 1 --request-id side-active --actor-binding lane-a-test > /dev/null
sleep 1.2
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-2 --holder-scope lane:a --request-id side-2-early --actor-binding lane-a-recovery
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease sweep \
  --request-id side-sweep --actor-binding operator > "$TMP_ROOT/side-sweep.json"
python3 - "$TMP_ROOT/side-sweep.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
item = next(item for item in value["data"]["expired"] if item["nodeId"] == "side-effect")
assert item["fromState"] == "active" and item["toState"] == "blocked" and item["reconciliation"] is True
PY
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve resolve-dependency complete \
  --lease-id resolve-dependency-1 --fence 1 --reason expired-unsafe --request-id resolve-dependency-bypass --actor-binding operator
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve resolve-validation complete \
  --lease-id resolve-validation-1 --fence 1 --reason expired-unsafe --request-id resolve-validation-bypass --actor-binding operator
expect_error 20 PRECONDITION_FAILED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve resolve-gated complete \
  --lease-id resolve-gated-1 --fence 1 --reason expired-unsafe --request-id resolve-gate-bypass --actor-binding operator
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-2 --holder-scope lane:a --request-id side-2-still-blocked --actor-binding lane-a-recovery
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve side-effect retry \
  --lease-id side-1 --fence 1 --reason expired-unsafe --request-id side-retry --actor-binding operator > /dev/null
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve cancel-task cancel \
  --lease-id cancel-1 --fence 1 --reason expired-unsafe --request-id cancel-resolve --actor-binding human > /dev/null
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve complete-task complete \
  --lease-id complete-1 --fence 1 --reason expired-unsafe --request-id complete-resolve --actor-binding operator > /dev/null
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire side-effect \
  --lease-id side-2 --holder-scope lane:a --request-id side-2 --actor-binding lane-a-recovery > "$TMP_ROOT/side-2.json"
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease renew side-effect \
  --lease-id side-1 --fence 1 --request-id side-stale-renew --actor-binding lane-a-test
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease release side-effect \
  --lease-id side-1 --fence 1 --request-id side-stale-release --actor-binding lane-a-test
expect_error 10 FENCE_STALE env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" transition side-effect ready \
  --lease-id side-1 --fence 1 --request-id side-stale-transition --actor-binding lane-a-test
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id safe-2 --holder-scope lane:a --request-id safe-2 --actor-binding lane-a-recovery > "$TMP_ROOT/safe-2.json"
python3 - "$TMP_ROOT/side-2.json" "$TMP_ROOT/safe-2.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    value = json.load(open(path, encoding="utf-8"))
    assert value["data"]["lease"]["fence"] == 2, value
PY
env OPERATOR_DIR="$TIME_DIR" bash "$GRAPH_SCRIPT" snapshot > "$TMP_ROOT/time-snapshot.json"
python3 - "$TMP_ROOT/time-snapshot.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
states = {node["id"]: node["state"] for node in value["nodes"]}
assert states["side-effect"] == "blocked"
assert states["cancel-task"] == "cancelled"
assert states["complete-task"] == "completed"
assert value["leaseFences"]["side-effect"] == 2
assert value["leaseFences"]["safe-task"] == 2
assert set(value["reconciliations"]) == {"resolve-dependency", "resolve-validation", "resolve-gated"}
PY

# Same-ID capability rotation cannot inherit a lease and old generations cannot replay after the rotation is observed.
ROTATE_DIR="$TMP_ROOT/rotate-operator"
write_bindings "$ROTATE_DIR"
env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id rotate-init --actor-binding operator > /dev/null
env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id rotate-lease-1 --holder-scope lane:a --request-id rotate-lease-1 --actor-binding lane-a-recovery > /dev/null
cp "$ROTATE_DIR/graph/bindings/lane-a-recovery.json" "$TMP_ROOT/lane-a-recovery-g1.json"
resign_binding "$ROTATE_DIR/graph/bindings/lane-a-recovery.json" 2
cp "$ROTATE_DIR/graph/bindings/lane-a-recovery.json" "$TMP_ROOT/lane-a-recovery-g2.json"
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease renew host-task \
  --lease-id rotate-lease-1 --fence 1 --request-id rotate-renew-denied --actor-binding lane-a-recovery
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease release host-task \
  --lease-id rotate-lease-1 --fence 1 --request-id rotate-release-denied --actor-binding lane-a-recovery
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" transition host-task ready \
  --lease-id rotate-lease-1 --fence 1 --request-id rotate-transition-denied --actor-binding lane-a-recovery
env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id generation-observer --holder-scope lane:a --request-id generation-observer --actor-binding lane-a-recovery > /dev/null
cp "$TMP_ROOT/lane-a-recovery-g1.json" "$ROTATE_DIR/graph/bindings/lane-a-recovery.json"
expect_error 8 AUTHORITY_DENIED env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease acquire cancel-task \
  --lease-id replayed-generation --holder-scope lane:a --request-id replayed-generation --actor-binding lane-a-recovery
cp "$TMP_ROOT/lane-a-recovery-g2.json" "$ROTATE_DIR/graph/bindings/lane-a-recovery.json"
env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease resolve host-task retry \
  --lease-id rotate-lease-1 --fence 1 --reason binding-rotated --request-id rotate-resolve --actor-binding operator > /dev/null
env OPERATOR_DIR="$ROTATE_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id rotate-lease-2 --holder-scope lane:a --request-id rotate-lease-2 --actor-binding lane-a-recovery > "$TMP_ROOT/rotate-lease-2.json"
python3 - "$TMP_ROOT/rotate-lease-2.json" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))["data"]["lease"]
assert lease["fence"] == 2 and lease["holder"]["bindingGeneration"] == 2
PY

# Rotation evidence must already be issued at the resolution event. A higher
# generation that was issued in the past remains historical evidence even when
# its validity window has since expired.
ROTATION_TIME_DIR="$TMP_ROOT/rotation-time-operator"
write_bindings "$ROTATION_TIME_DIR"
env OPERATOR_DIR="$ROTATION_TIME_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id rotation-time-init --actor-binding operator > /dev/null
env OPERATOR_DIR="$ROTATION_TIME_DIR" bash "$GRAPH_SCRIPT" lease acquire host-task \
  --lease-id rotation-time-lease --holder-scope lane:a --request-id rotation-time-lease --actor-binding lane-a-recovery > /dev/null
resign_binding "$ROTATION_TIME_DIR/graph/bindings/lane-a-recovery.json" 2 - - \
  2099-01-01T00:00:00Z 2098-01-01T00:00:00Z
expect_error 22 RECONCILIATION_REQUIRED env OPERATOR_DIR="$ROTATION_TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve host-task retry \
  --lease-id rotation-time-lease --fence 1 --reason binding-rotated --request-id future-rotation --actor-binding operator
resign_binding "$ROTATION_TIME_DIR/graph/bindings/lane-a-recovery.json" 3 - - \
  2021-01-01T00:00:00Z 2020-01-01T00:00:00Z
env OPERATOR_DIR="$ROTATION_TIME_DIR" bash "$GRAPH_SCRIPT" lease resolve host-task retry \
  --lease-id rotation-time-lease --fence 1 --reason binding-rotated --request-id expired-issued-rotation --actor-binding operator > /dev/null
env OPERATOR_DIR="$ROTATION_TIME_DIR" bash "$GRAPH_SCRIPT" replay check > /dev/null

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

# Host-aware lock rules: foreign/skewed and paused owners fail closed; only proven-dead or grace-aged malformed locks recover.
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
        "epoch": graph.host_monotonic_ns(),
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
try:
    with graph.DirectoryLock(foreign, timeout=0.08, lease_seconds=1):
        raise AssertionError("foreign expired lock was stolen from wall-clock comparison")
except graph.GraphError as error:
    assert error.code == "LOCK_TIMEOUT", error.code

reused = root / "reused-lock" / ".lock"
reused.mkdir(parents=True)
graph.atomic_write_json(reused / "owner.json", owner(processStart="definitely-not-current"))
with graph.DirectoryLock(reused, timeout=0.2, lease_seconds=1):
    pass

paused = root / "paused-lock" / ".lock"
paused.parent.mkdir(parents=True)
with graph.DirectoryLock(paused, timeout=0.2, lease_seconds=0.05) as held:
    import time
    time.sleep(0.08)
    try:
        with graph.DirectoryLock(paused, timeout=0.08, lease_seconds=0.05):
            raise AssertionError("paused live owner was split-brained")
    except graph.GraphError as error:
        assert error.code == "LOCK_TIMEOUT", error.code
    held.assert_owned()

ownerless = root / "ownerless-lock" / ".lock"
ownerless.mkdir(parents=True)
try:
    with graph.DirectoryLock(ownerless, timeout=0.08, lease_seconds=1):
        raise AssertionError("fresh ownerless lock was quarantined without grace")
except graph.GraphError as error:
    assert error.code == "LOCK_TIMEOUT", error.code
old = graph.time.time() - graph.OWNERLESS_LOCK_GRACE_SECONDS - 1
os.utime(ownerless, (old, old))
with graph.DirectoryLock(ownerless, timeout=0.2, lease_seconds=1):
    pass

failed = root / "owner-write-failure" / ".lock"
failed.parent.mkdir(parents=True)
original_write = graph.atomic_write_json
def broken_write(path, value):
    raise graph.GraphError("IO_ERROR", "injected test harness owner write failure")
graph.atomic_write_json = broken_write
try:
    try:
        with graph.DirectoryLock(failed, timeout=0.1):
            pass
    except graph.GraphError as error:
        assert error.code == "IO_ERROR", error.code
    assert not failed.exists(), "creator left an ownerless lock"
finally:
    graph.atomic_write_json = original_write

fenced = root / "fenced-replacement" / ".lock"
fenced.parent.mkdir(parents=True)
target = fenced.parent / "projection.json"
with graph.DirectoryLock(fenced, timeout=0.2, lease_seconds=1) as held:
    def lose_before_replace():
        owner_path = fenced / "owner.json"
        value = graph.read_json_file(owner_path, "LOCK_TIMEOUT", "LOCK_TIMEOUT", graph.MAX_BINDING_BYTES)
        value["token"] = "replacement-owner"
        original_write(owner_path, value)
        held.assert_owned()
    try:
        graph.atomic_write_json(target, {"mustNot": "replace"}, lose_before_replace)
        raise AssertionError("materialization replaced after lock ownership loss")
    except graph.GraphError as error:
        assert error.code == "LOCK_TIMEOUT", error.code
    assert not target.exists()

foreign_lease = {"clock": {"hostId": "foreign-host", "bootId": "foreign-boot", "monotonicSource": "macos-mach-continuous",
                           "acquiredMonotonicNs": 1, "expiresMonotonicNs": 2}}
try:
    graph.lease_clock_expired(foreign_lease, {"hostId": graph.HOST_ID, "bootId": graph.BOOT_ID,
                                             "monotonicSource": "macos-mach-continuous", "monotonicNs": 10**30}, "RECONCILIATION_REQUIRED")
    raise AssertionError("foreign lease expired from a skewed local clock")
except graph.GraphError as error:
    assert error.code == "RECONCILIATION_REQUIRED", error.code
PY

# Replay must reject semantically impossible leases even when an actor with the
# correct private key has fully re-signed the canonical authorization and event.
SIGNED_LEASE_DIR="$TMP_ROOT/signed-lease-source"
write_bindings "$SIGNED_LEASE_DIR"
env OPERATOR_DIR="$SIGNED_LEASE_DIR" bash "$GRAPH_SCRIPT" init --definition "$DEFINITION" \
  --request-id signed-lease-init --actor-binding operator > /dev/null
env OPERATOR_DIR="$SIGNED_LEASE_DIR" bash "$GRAPH_SCRIPT" transition complete-task cancelled \
  --request-id signed-terminal --actor-binding operator > /dev/null
env OPERATOR_DIR="$SIGNED_LEASE_DIR" bash "$GRAPH_SCRIPT" lease acquire safe-task \
  --lease-id forged-lease --holder-scope lane:a --ttl-seconds 300 --request-id signed-acquire --actor-binding lane-a > /dev/null
env OPERATOR_DIR="$SIGNED_LEASE_DIR" bash "$GRAPH_SCRIPT" lease renew safe-task \
  --lease-id forged-lease --fence 1 --ttl-seconds 600 --request-id signed-renew --actor-binding lane-a > /dev/null
for mutation in terminal-acquire invalid-ttl generated-id holder-divergence renewal-reshape; do
  target="$TMP_ROOT/signed-forge-$mutation"
  copy_state "$SIGNED_LEASE_DIR" "$target"
  python3 "$SIGNED_EVENT_FORGER" "$target/graph/events.jsonl" "$mutation" "$PROOF_KEY_DIR/lane-a.pem"
  expect_error 13 CORRUPT_JOURNAL env OPERATOR_DIR="$target" bash "$GRAPH_SCRIPT" replay check
done

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

# Initialized history pins the authority identity/hash; swapping the readable
# anchor without rewriting authenticated history fails closed.
ANCHOR_SWAP_DIR="$TMP_ROOT/anchor-swap"
copy_state "$MAIN_DIR" "$ANCHOR_SWAP_DIR"
python3 - "$ANCHOR_SWAP_DIR/authority/control-graph-public-key.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["keyId"] = "substituted-anchor"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
expect_error 13 CORRUPT_JOURNAL env OPERATOR_DIR="$ANCHOR_SWAP_DIR" bash "$GRAPH_SCRIPT" replay check

# Sequence, identity, authorization hashes, canonical intent/CAS, and middle records are replay-verified.
for mutation in bad-sequence duplicate-event-id middle invalid-time invalid-result invalid-lease nan-event bad-binding-hash bad-capability-hash bad-signature bad-fingerprint bad-intent bad-cas coherent-rewrite; do
  target="$TMP_ROOT/corrupt-$mutation"
  copy_state "$MAIN_DIR" "$target"
  python3 - "$target/graph/events.jsonl" "$mutation" <<'PY'
import json, sys
path, mutation = sys.argv[1:]
lines = open(path, "r", encoding="utf-8").readlines()
if mutation == "middle":
    lines[1] = "{broken-json}\n"
else:
    index = 1
    if mutation == "coherent-rewrite":
        index = next(i for i, raw in enumerate(lines) if json.loads(raw)["type"] == "node.transitioned")
    event = json.loads(lines[index])
    if mutation == "bad-sequence":
        event["sequence"] = 99
    elif mutation == "duplicate-event-id":
        event["eventId"] = json.loads(lines[0])["eventId"]
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
    elif mutation == "bad-binding-hash":
        event["actor"]["bindingHash"] = "sha256:" + "0" * 64
    elif mutation == "bad-capability-hash":
        event["actor"]["capabilityHash"] = "sha256:" + "0" * 64
    elif mutation == "bad-signature":
        event["actor"]["signature"] = ("A" if event["actor"]["signature"][0] != "A" else "B") + event["actor"]["signature"][1:]
    elif mutation == "bad-fingerprint":
        event["requestFingerprint"] = "sha256:" + "0" * 64
    elif mutation == "bad-intent":
        event["intent"]["nodeId"] = "forged-intent"
    elif mutation == "bad-cas":
        event["expectedRevision"] = 999
        payload = {"schemaVersion": "operator.mutation-proof-request/v1", "command": event["result"]["command"],
                   "requestId": event["requestId"], "bindingId": event["actor"]["bindingId"],
                   "bindingGeneration": event["actor"]["bindingGeneration"], "bindingHash": event["actor"]["bindingHash"],
                   "intent": event["intent"], "expectedRevision": event["expectedRevision"]}
        import hashlib
        raw = (json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        event["requestFingerprint"] = "sha256:" + hashlib.sha256(raw).hexdigest()
    elif mutation == "coherent-rewrite":
        event["intent"]["targetState"] = "blocked"
        event["data"]["to"] = "blocked"
        event["result"]["data"] = dict(event["data"])
        payload = {"schemaVersion": "operator.mutation-proof-request/v1", "command": event["result"]["command"],
                   "requestId": event["requestId"], "bindingId": event["actor"]["bindingId"],
                   "bindingGeneration": event["actor"]["bindingGeneration"], "bindingHash": event["actor"]["bindingHash"],
                   "intent": event["intent"], "expectedRevision": event["expectedRevision"]}
        import hashlib
        raw = (json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        event["requestFingerprint"] = "sha256:" + hashlib.sha256(raw).hexdigest()
    else:
        event["result"]["data"]["poison"] = float("nan")
    lines[index] = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
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

# Runtime materializations and authorization snapshots conform to committed schema field/capability contracts.
python3 - "$KIT_ROOT/schemas/operator-v5" "$MAIN_DIR/graph" "$TMP_ROOT/snapshot.json" <<'PY'
import copy, datetime as dt, json, re, sys
from pathlib import Path
schemas, graph_dir, snapshot_path = map(Path, sys.argv[1:])

class SchemaError(Exception):
    pass

def load_schema(name):
    return json.load(open(schemas / name, encoding="utf-8"))

def pointer(root, fragment):
    value = root
    if fragment:
        assert fragment.startswith("/")
        for part in fragment[1:].split("/"):
            value = value[part.replace("~1", "/").replace("~0", "~")]
    return value

def check(value, schema, root=None, source=None, path="$", quiet=False):
    root = schema if root is None else root
    source = source or "<inline>"
    try:
        if "$ref" in schema:
            ref = schema["$ref"]
            if ref.startswith("#"):
                return check(value, pointer(root, ref[1:]), root, source, path)
            name, _, fragment = ref.partition("#")
            external = load_schema(name)
            return check(value, pointer(external, fragment), external, name, path)
        if "allOf" in schema:
            for item in schema["allOf"]: check(value, item, root, source, path)
        if "anyOf" in schema:
            if not any(matches(value, item, root, source, path) for item in schema["anyOf"]):
                raise SchemaError(f"{path}: no anyOf branch matched")
        if "oneOf" in schema:
            if sum(matches(value, item, root, source, path) for item in schema["oneOf"]) != 1:
                raise SchemaError(f"{path}: expected exactly one oneOf branch")
        if "not" in schema and matches(value, schema["not"], root, source, path):
            raise SchemaError(f"{path}: forbidden schema matched")
        if "if" in schema and matches(value, schema["if"], root, source, path):
            if "then" in schema: check(value, schema["then"], root, source, path)
        elif "else" in schema:
            check(value, schema["else"], root, source, path)
        expected_type = schema.get("type")
        if expected_type is not None:
            choices = expected_type if isinstance(expected_type, list) else [expected_type]
            type_match = {
                "object": lambda: isinstance(value, dict),
                "array": lambda: isinstance(value, list),
                "string": lambda: isinstance(value, str),
                "integer": lambda: isinstance(value, int) and not isinstance(value, bool),
                "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool),
                "boolean": lambda: isinstance(value, bool),
                "null": lambda: value is None,
            }
            if not any(type_match[item]() for item in choices):
                raise SchemaError(f"{path}: type mismatch {choices}")
        if "const" in schema and value != schema["const"]:
            raise SchemaError(f"{path}: const mismatch")
        if "enum" in schema and value not in schema["enum"]:
            raise SchemaError(f"{path}: enum mismatch")
        if isinstance(value, dict):
            required = set(schema.get("required", []))
            if not required <= set(value):
                raise SchemaError(f"{path}: missing {sorted(required - set(value))}")
            if len(value) > schema.get("maxProperties", len(value)):
                raise SchemaError(f"{path}: too many properties")
            properties = schema.get("properties", {})
            extra = set(value) - set(properties)
            additional = schema.get("additionalProperties", True)
            if additional is False and extra:
                raise SchemaError(f"{path}: extra {sorted(extra)}")
            for key, item in value.items():
                if key in properties:
                    check(item, properties[key], root, source, f"{path}.{key}")
                elif isinstance(additional, dict):
                    check(item, additional, root, source, f"{path}.{key}")
        if isinstance(value, list):
            if len(value) > schema.get("maxItems", len(value)) or len(value) < schema.get("minItems", 0):
                raise SchemaError(f"{path}: array size")
            if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
                raise SchemaError(f"{path}: duplicate items")
            if isinstance(schema.get("items"), dict):
                for index, item in enumerate(value): check(item, schema["items"], root, source, f"{path}[{index}]")
        if isinstance(value, str):
            if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", len(value)):
                raise SchemaError(f"{path}: string length")
            if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
                raise SchemaError(f"{path}: pattern")
            if schema.get("format") == "date-time":
                dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if value < schema.get("minimum", value) or value > schema.get("maximum", value):
                raise SchemaError(f"{path}: numeric bound")
    except (AssertionError, KeyError, ValueError, TypeError, SchemaError) as error:
        if quiet: return False
        if isinstance(error, SchemaError): raise
        raise SchemaError(f"{path}: {error}") from error
    return True

def matches(value, schema, root, source, path):
    try:
        check(value, schema, root, source, path)
        return True
    except SchemaError:
        return False

binding_schema = json.load(open(schemas / "actor-binding.schema.json", encoding="utf-8"))
binding = json.load(open(graph_dir / "bindings" / "operator.json", encoding="utf-8"))
check(binding, binding_schema, binding_schema, "actor-binding.schema.json")
event_schema = load_schema("control-event.schema.json")
events = [json.loads(line) for line in open(graph_dir / "events.jsonl", encoding="utf-8")]
for event in events:
    check(event, event_schema, event_schema, "control-event.schema.json")
projection_schema = load_schema("control-projection.schema.json")
projection = json.load(open(graph_dir / "projection.json", encoding="utf-8"))
check(projection, projection_schema, projection_schema, "control-projection.schema.json")
snapshot_schema = load_schema("control-snapshot.schema.json")
snapshot = json.load(open(snapshot_path, encoding="utf-8"))["data"]
check(snapshot, snapshot_schema, snapshot_schema, "control-snapshot.schema.json")

authorization_schema = load_schema("mutation-authorization.schema.json")
unsigned_schema = load_schema("control-event-unsigned.schema.json")
event_payload_schema = load_schema("mutation-event-proof-payload.schema.json")
challenge_schema = load_schema("proof-broker-challenge.schema.json")
response_schema = load_schema("proof-broker-response.schema.json")
first = events[0]
authorization = {
    "schemaVersion": "operator.mutation-proof-request/v1", "command": first["result"]["command"],
    "requestId": first["requestId"], "bindingId": first["actor"]["bindingId"],
    "bindingGeneration": first["actor"]["bindingGeneration"], "bindingHash": first["actor"]["bindingHash"],
    "intent": first["intent"], "expectedRevision": first["expectedRevision"],
}
unsigned_event = {key: value for key, value in first.items() if key != "proof"}
event_payload = {"schemaVersion": "operator.mutation-event-proof/v1", "event": unsigned_event}
check(authorization, authorization_schema, authorization_schema, "mutation-authorization.schema.json")
check(unsigned_event, unsigned_schema, unsigned_schema, "control-event-unsigned.schema.json")
check(event_payload, event_payload_schema, event_payload_schema, "mutation-event-proof-payload.schema.json")
for phase, payload, signature in (
    ("authorize", authorization, first["proof"]["authorizationSignature"]),
    ("event", event_payload, first["proof"]["eventSignature"]),
):
    challenge = {"schemaVersion": "operator.proof-challenge/v1", "operation": "sign", "phase": phase,
                 "proofKeyId": first["proof"]["proofKeyId"], "payload": payload}
    response = {"schemaVersion": "operator.proof-response/v1", "phase": phase,
                "proofKeyId": first["proof"]["proofKeyId"], "signature": signature}
    check(challenge, challenge_schema, challenge_schema, "proof-broker-challenge.schema.json")
    check(response, response_schema, response_schema, "proof-broker-response.schema.json")

negative_snapshots = []
bad = copy.deepcopy(snapshot)
next(iter(bad["executionStarted"].values()))["revision"] = 0
negative_snapshots.append(bad)
bad = copy.deepcopy(snapshot)
bad["reconciliations"]["malformed"] = {"leaseId": "x", "fence": 1, "reason": "invented"}
negative_snapshots.append(bad)
bad = copy.deepcopy(snapshot)
next(iter(bad["bindingGenerations"].values()))["bindingHash"] = "not-a-hash"
negative_snapshots.append(bad)
for bad in negative_snapshots:
    assert not matches(bad, snapshot_schema, snapshot_schema, "control-snapshot.schema.json", "$")
PY

ROADMAP_AFTER="$(shasum -a 256 "$MAIN_DIR/roadmap/sentinel.txt")"
[ "$ROADMAP_BEFORE" = "$ROADMAP_AFTER" ] || fail "graph commands mutated roadmap state"
[ "$(find "$MAIN_DIR/roadmap" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "graph commands added roadmap files"

printf 'operator v5 control graph adversarial smoke ok: %s\n' "$MAIN_DIR"
