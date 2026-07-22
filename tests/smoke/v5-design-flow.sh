#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG PROJECT_NAME PROJECT_ROOT CODE_DIR TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES

TEST_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIT_ROOT="${OPERATOR_KIT_TEST_ROOT:-$TEST_SOURCE_ROOT}"
PRODUCTION_DESIGN_FLOW="$KIT_ROOT/scripts/operator-design-flow.sh"
DESIGN_FLOW="$PRODUCTION_DESIGN_FLOW"
SCHEDULER="$KIT_ROOT/scripts/operator-scheduler.sh"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-design-flow.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

installed_operator_dir="${OPERATOR_DESIGN_FLOW_TEST_OPERATOR_DIR:-}"
if [ -n "$installed_operator_dir" ]; then
  export OPERATOR_DIR="$installed_operator_dir"
  unset OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT
else
  export OPERATOR_DIR="$TMP_ROOT/operator"
  unset OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT
fi
FEATURE_DIR="$OPERATOR_DIR/features/FS-0008-rm-0006-design-flow"
FEATURE_TWO_DIR="$OPERATOR_DIR/features/FS-0009-rm-0006-design-flow-two"
SNAPSHOT="$TMP_ROOT/snapshot.json"
GRAPH_LOG="$TMP_ROOT/graph-requests.jsonl"
FEEDBACK_LOG="$TMP_ROOT/feedback-requests.jsonl"
mkdir -p "$FEATURE_DIR" "$FEATURE_TWO_DIR" "$OPERATOR_DIR/graph/bindings" \
  "$OPERATOR_DIR/authority" "$OPERATOR_DIR/host" "$OPERATOR_DIR/prompts"
printf '{}\n' > "$OPERATOR_DIR/authority/control-graph-public-key.json"
if [ -z "$installed_operator_dir" ]; then
  cp "$TEST_SOURCE_ROOT/templates/prompts/design-proposal.md" "$OPERATOR_DIR/prompts/design-proposal.md"
else
  test -f "$OPERATOR_DIR/prompts/design-proposal.md"
  mkdir -p "$KIT_ROOT/templates/prompts"
  printf 'REPO_LOCAL_DESIGN_PROMPT_POISON\n' > "$KIT_ROOT/templates/prompts/design-proposal.md"
fi
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

cat > "$TMP_ROOT/snapshot-provider" <<'PY'
#!/usr/bin/env python3
import os, pathlib, stat, time

def validate_root():
    assert os.environ["OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE"] == "exclusive-held"
    fd = int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_FD"])
    identity = (int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_DEV"]),
                int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_INO"]))
    path = os.environ["OPERATOR_DESIGN_FLOW_ROOT_PATH"]
    assert os.environ["OPERATOR_DIR"] == path
    held = os.fstat(fd)
    assert stat.S_ISDIR(held.st_mode) and (held.st_dev, held.st_ino) == identity
    expected = os.lstat(path)
    assert stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        actual = os.fstat(descriptor)
        assert (expected.st_dev, expected.st_ino) == identity == (actual.st_dev, actual.st_ino)
    finally:
        os.close(descriptor)
    graph_fd = os.open("graph", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
    marker_fd = os.open("DO-NOT-READ", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=graph_fd)
    try:
        assert os.read(marker_fd, 4096) == b"control-owned marker\n"
    finally:
        os.close(marker_fd)
        os.close(graph_fd)

ready = os.environ.get("DESIGN_SMOKE_SNAPSHOT_READY")
if ready:
    pathlib.Path(ready).touch()
    go = pathlib.Path(os.environ["DESIGN_SMOKE_SNAPSHOT_GO"])
    while not go.exists():
        time.sleep(0.01)
validate_root()
os.execv("/bin/cat", ["cat", os.environ["DESIGN_SMOKE_SNAPSHOT"]])
PY
chmod +x "$TMP_ROOT/snapshot-provider"

cat > "$TMP_ROOT/graph-launcher" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, stat, sys, time

def validate_root():
    assert os.environ["OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE"] == "exclusive-held"
    fd = int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_FD"])
    identity = (int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_DEV"]),
                int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_INO"]))
    path = os.environ["OPERATOR_DESIGN_FLOW_ROOT_PATH"]
    assert os.environ["OPERATOR_DIR"] == path
    held = os.fstat(fd)
    assert stat.S_ISDIR(held.st_mode) and (held.st_dev, held.st_ino) == identity
    expected = os.lstat(path)
    assert stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        actual = os.fstat(descriptor)
        assert (expected.st_dev, expected.st_ino) == identity == (actual.st_dev, actual.st_ino)
    finally:
        os.close(descriptor)
    graph_fd = os.open("graph", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
    marker_fd = os.open("DO-NOT-READ", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=graph_fd)
    try:
        assert os.read(marker_fd, 4096) == b"control-owned marker\n"
    finally:
        os.close(marker_fd)
        os.close(graph_fd)

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
required = {"schemaVersion","command","requestId","graphId","expectedRevision","cliIntent","definition","gateNodeId","decision"}
assert set(request) == required
assert request["schemaVersion"] == "operator.design-flow-graph-mutation-request/v1"
assert request["cliIntent"]["action"] in {"start","select","reject","improve"}
assert "actorBinding" not in request and "proofFd" not in request and "authorityKey" not in request

ready = os.environ.get("DESIGN_SMOKE_MUTATION_READY")
if ready:
    pathlib.Path(ready).touch()
    go = pathlib.Path(os.environ["DESIGN_SMOKE_MUTATION_GO"])
    while not go.exists():
        time.sleep(0.01)
validate_root()

snapshot_path = pathlib.Path(os.environ["DESIGN_SMOKE_SNAPSHOT"])
log_path = pathlib.Path(os.environ["DESIGN_SMOKE_GRAPH_LOG"])
snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
if request["graphId"] != snapshot["graphId"] or request["expectedRevision"] != snapshot["revision"]:
    print('{"error":{"code":"REVISION_CONFLICT","message":"stale"},"ok":false}', file=sys.stderr)
    raise SystemExit(9)

command = request["command"]
if command == "replace-definition":
    assert request["gateNodeId"] is None and request["decision"] is None
    fail_once = os.environ.get("DESIGN_SMOKE_FAIL_REPLACE_ONCE")
    if (fail_once and request["cliIntent"]["action"] == "select"
            and pathlib.Path(fail_once).exists()):
        pathlib.Path(fail_once).unlink()
        print('{"error":{"code":"BROKER_UNAVAILABLE","message":"injected"},"ok":false}', file=sys.stderr)
        raise SystemExit(7)
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
import json, os, pathlib, stat, sys, time

def validate_root():
    assert os.environ["OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE"] == "exclusive-held"
    fd = int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_FD"])
    identity = (int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_DEV"]),
                int(os.environ["OPERATOR_DESIGN_FLOW_ROOT_INO"]))
    path = os.environ["OPERATOR_DESIGN_FLOW_ROOT_PATH"]
    assert os.environ["OPERATOR_DIR"] == path
    held = os.fstat(fd)
    assert stat.S_ISDIR(held.st_mode) and (held.st_dev, held.st_ino) == identity
    expected = os.lstat(path)
    assert stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        actual = os.fstat(descriptor)
        assert (expected.st_dev, expected.st_ino) == identity == (actual.st_dev, actual.st_ino)
    finally:
        os.close(descriptor)
    graph_fd = os.open("graph", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
    marker_fd = os.open("DO-NOT-READ", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=graph_fd)
    try:
        assert os.read(marker_fd, 4096) == b"control-owned marker\n"
    finally:
        os.close(marker_fd)
        os.close(graph_fd)

request = json.load(sys.stdin)
required = {"schemaVersion","requestId","featureId","flowId","improvementNodeId","sourceNodeId",
            "message","messageHash","evidencePath","evidence"}
assert set(request) == required
assert request["schemaVersion"] == "operator.design-flow-feedback-request/v1"
assert request["evidencePath"].startswith("work/design-options/improvements/")
ready = os.environ.get("DESIGN_SMOKE_FEEDBACK_READY")
if ready:
    pathlib.Path(ready).touch()
    go = pathlib.Path(os.environ["DESIGN_SMOKE_FEEDBACK_GO"])
    while not go.exists():
        time.sleep(0.01)
validate_root()
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
export DESIGN_SMOKE_SNAPSHOT_PROVIDER="$TMP_ROOT/snapshot-provider"
export DESIGN_SMOKE_MUTATION_PROVIDER="$TMP_ROOT/graph-launcher"
export DESIGN_SMOKE_FEEDBACK_PROVIDER="$TMP_ROOT/feedback-owner"
fixture_runtime="$TMP_ROOT/scripts"
mkdir -p "$fixture_runtime"
cp "$PRODUCTION_DESIGN_FLOW" "$fixture_runtime/operator-design-flow.sh"
/usr/bin/python3 -E -s - "$fixture_runtime/operator-design-flow.sh" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "    root.refresh_mutable_graph_leaves(request_id, expected_revision + 1)\n"
assert text.count(needle) == 1
path.write_text(text.replace(needle, "    # Fake graph fixture has no RM-0007 materialization.\n"), encoding="utf-8")
PY
cp "$TEST_SOURCE_ROOT/scripts/operator-bootstrap.sh" "$fixture_runtime/operator-bootstrap.sh"
mkdir -p "$TMP_ROOT/plugins/operator-kit/.codex-plugin" "$TMP_ROOT/templates/prompts"
cp "$TEST_SOURCE_ROOT/plugins/operator-kit/.codex-plugin/plugin.json" \
  "$TMP_ROOT/plugins/operator-kit/.codex-plugin/plugin.json"
cp "$TEST_SOURCE_ROOT/templates/prompts/design-proposal.md" \
  "$TMP_ROOT/templates/prompts/design-proposal.md"
cat > "$fixture_runtime/operator-graph.sh" <<'SH'
#!/bin/sh
set -eu
case "${OPERATOR_DESIGN_FLOW_PROVIDER_MODE:-}" in
  snapshot) exec "$DESIGN_SMOKE_SNAPSHOT_PROVIDER" ;;
  mutation) exec "$DESIGN_SMOKE_MUTATION_PROVIDER" ;;
  *) printf 'unexpected fixture graph provider mode\n' >&2; exit 2 ;;
esac
SH
cat > "$fixture_runtime/operator-feedback.sh" <<'SH'
#!/bin/sh
set -eu
[ "${OPERATOR_DESIGN_FLOW_PROVIDER_MODE:-}" = feedback ] || exit 2
exec "$DESIGN_SMOKE_FEEDBACK_PROVIDER"
SH
chmod 755 "$fixture_runtime/operator-design-flow.sh" "$fixture_runtime/operator-graph.sh" \
  "$fixture_runtime/operator-feedback.sh"
DESIGN_FLOW="$fixture_runtime/operator-design-flow.sh"
export OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT="$TMP_ROOT"

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

assert_root_identity_error() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["ok"] is False and value["error"]["code"] == "IO_ERROR", value
assert "OPERATOR_DIR identity changed" in value["error"]["message"], value
PY
}

file_state() {
  if [ -e "$1" ]; then
    shasum -a 256 "$1"
  else
    printf 'missing\n'
  fi
}

tree_state() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib, json, os, stat, sys
root = os.path.abspath(sys.argv[1])
result = {}
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    directories.sort()
    files.sort()
    for name in ["."] + directories + files if current == root else directories + files:
        path = current if name == "." else os.path.join(current, name)
        info = os.lstat(path)
        key = os.path.relpath(path, root)
        item = {"dev": info.st_dev, "ino": info.st_ino, "mode": info.st_mode,
                "nlink": info.st_nlink, "size": info.st_size,
                "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}
        if stat.S_ISREG(info.st_mode):
            with open(path, "rb") as handle:
                item["sha256"] = hashlib.sha256(handle.read()).hexdigest()
        elif stat.S_ISLNK(info.st_mode):
            item["target"] = os.readlink(path)
        result[key] = item
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

wait_for_root_lock() {
  /usr/bin/python3 - "$1" <<'PY'
import fcntl, os, sys, time
descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
deadline = time.monotonic() + 10
try:
    while time.monotonic() < deadline:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(0)
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            time.sleep(0.01)
    raise SystemExit("production provider did not retain the inherited root lock")
finally:
    os.close(descriptor)
PY
}

feature_state() {
  find "$FEATURE_DIR" -type f -exec shasum -a 256 {} \; | sort
}

root_swap_at_interface() {
  local label="$1"
  local ready_name="$2"
  local go_name="$3"
  shift 3
  local ready="$TMP_ROOT/$label-ready"
  local go="$TMP_ROOT/$label-go"
  local original="${OPERATOR_DIR}.$label-original.$$"
  local replacement="${OPERATOR_DIR}.$label-replacement.$$"
  local output="$TMP_ROOT/$label.out"
  local error="$TMP_ROOT/$label.err"
  local snapshot_before graph_before feedback_before artifacts_before
  snapshot_before="$(file_state "$SNAPSHOT")"
  graph_before="$(file_state "$GRAPH_LOG")"
  feedback_before="$(file_state "$FEEDBACK_LOG")"
  artifacts_before="$(feature_state)"
  mkdir -p "$replacement/graph" "$replacement/prompts" "$replacement/features/poison-feature"
  printf 'OPERATOR_ROOT_EFFECT_POISON\n' > "$replacement/graph/DO-NOT-READ"
  printf 'OPERATOR_ROOT_EFFECT_POISON\n' > "$replacement/prompts/design-proposal.md"
  printf '{"id":"POISON","slug":"poison"}\n' > "$replacement/features/poison-feature/status.json"
  export "$ready_name=$ready"
  export "$go_name=$go"
  "$@" > "$output" 2> "$error" &
  local command_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$ready" ] && break
    sleep 0.01
  done
  test -e "$ready"
  mv "$OPERATOR_DIR" "$original"
  mv "$replacement" "$OPERATOR_DIR"
  touch "$go"
  set +e
  wait "$command_pid"
  local command_rc=$?
  mv "$OPERATOR_DIR" "$replacement"
  local replacement_restore_rc=$?
  mv "$original" "$OPERATOR_DIR"
  local original_restore_rc=$?
  set -e
  unset "$ready_name" "$go_name"
  test "$command_rc" -ne 0
  test "$replacement_restore_rc" -eq 0
  test "$original_restore_rc" -eq 0
  assert_root_identity_error "$error"
  test "$snapshot_before" = "$(file_state "$SNAPSHOT")"
  test "$graph_before" = "$(file_state "$GRAPH_LOG")"
  test "$feedback_before" = "$(file_state "$FEEDBACK_LOG")"
  test "$artifacts_before" = "$(feature_state)"
  test ! -e "$replacement/work"
  if rg -n 'OPERATOR_ROOT_EFFECT_POISON' "$OPERATOR_DIR"; then
    printf '%s root-swap poison reached the original workspace\n' "$label" >&2
    exit 1
  fi
  rm -rf "$replacement"
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

# Installed design status defaults to the real operator-graph launcher. Hold a
# production graph lock after its inherited-root validation, replace the
# configured pathname, and prove the nested graph runtime remains descriptor
# anchored: it may fail on the original uninitialized graph, but it must not
# read, lock, repair, or otherwise touch the poison replacement graph.
if [ -n "$installed_operator_dir" ]; then
  production_graph_original="${OPERATOR_DIR}.production-graph-original.$$"
  production_graph_replacement="${OPERATOR_DIR}.production-graph-replacement.$$"
  production_graph_error="$TMP_ROOT/production-graph-swap.err"
  mkdir -p "$OPERATOR_DIR/graph/.lock" "$production_graph_replacement/graph" \
    "$production_graph_replacement/prompts"
  printf 'block production graph provider\n' > "$OPERATOR_DIR/graph/.lock/unexpected"
  printf 'OPERATOR_PRODUCTION_GRAPH_REPLACEMENT_POISON\n' > "$production_graph_replacement/graph/poison"
  printf 'OPERATOR_PRODUCTION_GRAPH_REPLACEMENT_POISON\n' > "$production_graph_replacement/prompts/design-proposal.md"
  bash "$PRODUCTION_DESIGN_FLOW" status --feature FS-0008 --json \
    > "$TMP_ROOT/production-graph-swap.out" 2> "$production_graph_error" &
  production_graph_pid=$!
  wait_for_root_lock "$OPERATOR_DIR"
  mv "$OPERATOR_DIR" "$production_graph_original"
  mv "$production_graph_replacement" "$OPERATOR_DIR"
  production_graph_replacement_before="$(tree_state "$OPERATOR_DIR")"
  rm "$production_graph_original/graph/.lock/unexpected"
  rmdir "$production_graph_original/graph/.lock"
  set +e
  wait "$production_graph_pid"
  production_graph_rc=$?
  set -e
  production_graph_replacement_after="$(tree_state "$OPERATOR_DIR")"
  mv "$OPERATOR_DIR" "$production_graph_replacement"
  mv "$production_graph_original" "$OPERATOR_DIR"
  test "$production_graph_rc" -ne 0
  assert_root_identity_error "$production_graph_error"
  test "$production_graph_replacement_before" = "$production_graph_replacement_after"
  if rg -n 'OPERATOR_PRODUCTION_GRAPH_REPLACEMENT_POISON' "$OPERATOR_DIR"; then
    printf 'production graph provider consumed replacement-root poison\n' >&2
    exit 1
  fi
  rm -rf "$production_graph_replacement"
fi

# Pause after the command has opened both its OPERATOR_DIR snapshot and feature
# artifact descriptor, then replace OPERATOR_DIR with a same-owner real tree
# containing a poison prompt. Prompt selection must reject the root identity
# change, write no artifacts, consume no poison, and issue no graph mutation.
root_swap_ready="$TMP_ROOT/root-swap-ready"
root_swap_go="$TMP_ROOT/root-swap-go"
root_swap_original="${OPERATOR_DIR}.design-flow-original.$$"
root_swap_replacement="${OPERATOR_DIR}.design-flow-replacement.$$"
mkdir -p "$root_swap_replacement/prompts"
printf 'OPERATOR_ROOT_SWAP_PROMPT_POISON\n' > "$root_swap_replacement/prompts/design-proposal.md"
export DESIGN_SMOKE_SNAPSHOT_READY="$root_swap_ready"
export DESIGN_SMOKE_SNAPSHOT_GO="$root_swap_go"
bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json \
  > "$TMP_ROOT/root-swap.out" 2> "$TMP_ROOT/root-swap.err" &
root_swap_pid=$!
for _ in $(seq 1 500); do
  [ -e "$root_swap_ready" ] && break
  sleep 0.01
done
test -e "$root_swap_ready"
mv "$OPERATOR_DIR" "$root_swap_original"
mv "$root_swap_replacement" "$OPERATOR_DIR"
touch "$root_swap_go"
set +e
wait "$root_swap_pid"
root_swap_rc=$?
mv "$OPERATOR_DIR" "$root_swap_replacement"
replacement_restore_rc=$?
mv "$root_swap_original" "$OPERATOR_DIR"
original_restore_rc=$?
set -e
test "$root_swap_rc" -ne 0
test "$replacement_restore_rc" -eq 0
test "$original_restore_rc" -eq 0
/usr/bin/python3 - "$TMP_ROOT/root-swap.err" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["ok"] is False and value["error"]["code"] == "IO_ERROR", value
assert "OPERATOR_DIR identity changed" in value["error"]["message"], value
PY
test ! -e "$FEATURE_DIR/work"
test ! -s "$GRAPH_LOG"
if rg -n 'OPERATOR_ROOT_SWAP_PROMPT_POISON' "$OPERATOR_DIR"; then
  printf 'root-swap poison was consumed into the original Operator workspace\n' >&2
  exit 1
fi
rm -rf "$root_swap_replacement"
unset DESIGN_SMOKE_SNAPSHOT_READY DESIGN_SMOKE_SNAPSHOT_GO

# Pause the real mutation boundary only after start has read the proposal
# prompt and published its descriptor-anchored proposal artifacts. A root
# replacement at that point must be rejected by the inherited FD/identity
# contract before graph mutation; artifacts remain wholly in the original
# feature and no replacement poison is consumed.
post_prompt_ready="$TMP_ROOT/post-prompt-ready"
post_prompt_go="$TMP_ROOT/post-prompt-go"
post_prompt_original="${OPERATOR_DIR}.post-prompt-original.$$"
post_prompt_replacement="${OPERATOR_DIR}.post-prompt-replacement.$$"
post_prompt_snapshot_before="$(file_state "$SNAPSHOT")"
mkdir -p "$post_prompt_replacement/graph" "$post_prompt_replacement/prompts"
printf 'OPERATOR_POST_PROMPT_POISON\n' > "$post_prompt_replacement/graph/DO-NOT-READ"
printf 'OPERATOR_POST_PROMPT_POISON\n' > "$post_prompt_replacement/prompts/design-proposal.md"
export DESIGN_SMOKE_MUTATION_READY="$post_prompt_ready"
export DESIGN_SMOKE_MUTATION_GO="$post_prompt_go"
bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json \
  > "$TMP_ROOT/post-prompt.out" 2> "$TMP_ROOT/post-prompt.err" &
post_prompt_pid=$!
for _ in $(seq 1 500); do
  [ -e "$post_prompt_ready" ] && break
  sleep 0.01
done
test -e "$post_prompt_ready"
test -f "$FEATURE_DIR/work/design-options/proposal-a/prompt.md"
mv "$OPERATOR_DIR" "$post_prompt_original"
mv "$post_prompt_replacement" "$OPERATOR_DIR"
touch "$post_prompt_go"
set +e
wait "$post_prompt_pid"
post_prompt_rc=$?
mv "$OPERATOR_DIR" "$post_prompt_replacement"
post_prompt_replacement_restore_rc=$?
mv "$post_prompt_original" "$OPERATOR_DIR"
post_prompt_original_restore_rc=$?
set -e
unset DESIGN_SMOKE_MUTATION_READY DESIGN_SMOKE_MUTATION_GO
test "$post_prompt_rc" -ne 0
test "$post_prompt_replacement_restore_rc" -eq 0
test "$post_prompt_original_restore_rc" -eq 0
assert_root_identity_error "$TMP_ROOT/post-prompt.err"
test "$post_prompt_snapshot_before" = "$(file_state "$SNAPSHOT")"
test ! -s "$GRAPH_LOG"
test -f "$FEATURE_DIR/work/design-options/proposal-a/prompt.md"
test ! -e "$post_prompt_replacement/work"
if rg -n 'OPERATOR_POST_PROMPT_POISON' "$OPERATOR_DIR"; then
  printf 'post-prompt root-swap poison reached the original workspace\n' >&2
  exit 1
fi
rm -rf "$post_prompt_replacement"

# A caller-controlled source-mode locator cannot suppress the shipped
# post-mutation replay contract.  This source-shaped test copy uses the fake
# mutation provider (which deliberately has no RM-0007 journal/materialization)
# and must therefore fail after the provider reports success.  Only the main
# fixture copy above is patched to emulate replay; no environment variable can
# disable verification in the distributed runtime.
replay_source="$TMP_ROOT/replay-security-source"
mkdir -p "$replay_source/scripts" "$replay_source/plugins/operator-kit/.codex-plugin" \
  "$replay_source/templates/prompts"
cp "$PRODUCTION_DESIGN_FLOW" "$replay_source/scripts/operator-design-flow.sh"
cp "$TEST_SOURCE_ROOT/scripts/operator-bootstrap.sh" "$replay_source/scripts/operator-bootstrap.sh"
cp "$fixture_runtime/operator-graph.sh" "$replay_source/scripts/operator-graph.sh"
cp "$fixture_runtime/operator-feedback.sh" "$replay_source/scripts/operator-feedback.sh"
cp "$TEST_SOURCE_ROOT/plugins/operator-kit/.codex-plugin/plugin.json" \
  "$replay_source/plugins/operator-kit/.codex-plugin/plugin.json"
cp "$TEST_SOURCE_ROOT/templates/prompts/design-proposal.md" \
  "$replay_source/templates/prompts/design-proposal.md"
chmod 755 "$replay_source/scripts/"*.sh
cp "$SNAPSHOT" "$TMP_ROOT/replay-security-snapshot.json"
rm -f "$GRAPH_LOG"
feature_backup="$TMP_ROOT/replay-security-feature"
cp -R "$FEATURE_DIR" "$feature_backup"
DESIGN_FLOW="$replay_source/scripts/operator-design-flow.sh"
export OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT="$replay_source"
expect_error IO_ERROR bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"
rm -rf "$FEATURE_DIR"
mv "$feature_backup" "$FEATURE_DIR"
mv "$TMP_ROOT/replay-security-snapshot.json" "$SNAPSHOT"
rm -f "$GRAPH_LOG"
DESIGN_FLOW="$fixture_runtime/operator-design-flow.sh"
export OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT="$TMP_ROOT"

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
    rendered = (options / proposal / "prompt.md").read_text(encoding="utf-8")
    assert "REPO_LOCAL_DESIGN_PROMPT_POISON" not in rendered
    assert "A human must choose a proposal via" in rendered
PY

# Start retries discover the durable graph shape and do not append again.
bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
  --lane design-lane --title "First value" --json > /dev/null
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"

if [ -n "$installed_operator_dir" ]; then
  # Exercise the fixture copy in installed mode: its trusted providers remain
  # local test siblings, but prompt selection must use only OPERATOR_DIR.
  unset OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT
  # An installed runtime never probes a repo-local template, including final
  # component and intermediate-directory symlink variants.
  printf 'REPO_LOCAL_FILE_SYMLINK_POISON\n' > "$TMP_ROOT/repo-file-poison.md"
  rm "$KIT_ROOT/templates/prompts/design-proposal.md"
  ln -s "$TMP_ROOT/repo-file-poison.md" "$KIT_ROOT/templates/prompts/design-proposal.md"
  bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
    --lane design-lane --title "First value" --json > /dev/null
  unlink "$KIT_ROOT/templates/prompts/design-proposal.md"
  rmdir "$KIT_ROOT/templates/prompts"
  mkdir -p "$TMP_ROOT/repo-prompts-poison"
  printf 'REPO_LOCAL_INTERMEDIATE_SYMLINK_POISON\n' > "$TMP_ROOT/repo-prompts-poison/design-proposal.md"
  ln -s "$TMP_ROOT/repo-prompts-poison" "$KIT_ROOT/templates/prompts"
  bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
    --lane design-lane --title "First value" --json > /dev/null
  unlink "$KIT_ROOT/templates/prompts"

  # The selected external prompt itself is fail-closed for both final and
  # intermediate symlinks; neither poison target can be consumed.
  mv "$OPERATOR_DIR/prompts/design-proposal.md" "$TMP_ROOT/external-prompt.md"
  ln -s "$TMP_ROOT/repo-file-poison.md" "$OPERATOR_DIR/prompts/design-proposal.md"
  expect_error IO_ERROR bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
    --lane design-lane --title "First value" --json
  unlink "$OPERATOR_DIR/prompts/design-proposal.md"
  mv "$TMP_ROOT/external-prompt.md" "$OPERATOR_DIR/prompts/design-proposal.md"
  mv "$OPERATOR_DIR/prompts" "$TMP_ROOT/external-prompts-real"
  ln -s "$TMP_ROOT/repo-prompts-poison" "$OPERATOR_DIR/prompts"
  expect_error IO_ERROR bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
    --lane design-lane --title "First value" --json
  unlink "$OPERATOR_DIR/prompts"
  mv "$TMP_ROOT/external-prompts-real" "$OPERATOR_DIR/prompts"

  # Source-template mode is unavailable to an installed runtime even when a
  # caller explicitly points the opt-in at the installed repository.
  export OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT="$KIT_ROOT"
  expect_error IO_ERROR bash "$DESIGN_FLOW" start --feature FS-0008 --brief "$TMP_ROOT/brief.md" \
    --lane design-lane --title "First value" --json
  export OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT="$TMP_ROOT"
fi

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

# Non-start commands bind the same held root across their trusted interfaces.
# Status is paused in snapshot delivery; reject and select are paused after
# their validated snapshot but before the graph launcher can mutate.
root_swap_at_interface status-root-swap DESIGN_SMOKE_SNAPSHOT_READY DESIGN_SMOKE_SNAPSHOT_GO \
  bash "$DESIGN_FLOW" status --feature FS-0008 --json
root_swap_at_interface reject-root-swap DESIGN_SMOKE_MUTATION_READY DESIGN_SMOKE_MUTATION_GO \
  bash "$DESIGN_FLOW" reject --feature FS-0008 --json
root_swap_at_interface select-root-swap DESIGN_SMOKE_MUTATION_READY DESIGN_SMOKE_MUTATION_GO \
  bash "$DESIGN_FLOW" select --feature FS-0008 --lane design-lane --proposal proposal-b --json
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "1"

# Inject a host failure after the human gate commit but before implementation
# materialization. Generic status must report the durable partial state, reject
# and dissatisfaction remain blocked, and select must resume after an unrelated
# graph revision without repeating the gate decision.
touch "$TMP_ROOT/fail-replace-once"
export DESIGN_SMOKE_FAIL_REPLACE_ONCE="$TMP_ROOT/fail-replace-once"
expect_error TRUSTED_INTERFACE_FAILED bash "$DESIGN_FLOW" select --feature FS-0008 \
  --lane design-lane --proposal proposal-b --json

python3 - "$SNAPSHOT" "$TMP_ROOT/clock.json" <<'PY'
import json, pathlib, sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
gate = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "selection-gate")
assert gate["state"] == "approved"
assert not any(item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation"
               for item in snapshot["nodes"])
clock = {"schemaVersion":"operator.scheduler-clock/v1","hostId":"smoke-host","bootId":"smoke-boot",
         "monotonicSource":"macos-mach-continuous","monotonicNs":1000000000}
pathlib.Path(sys.argv[2]).write_text(json.dumps(clock, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "2"
bash "$DESIGN_FLOW" status --feature FS-0008 --json > "$TMP_ROOT/partial-status.json"
python3 - "$TMP_ROOT/partial-status.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
assert data["selection"]["gateState"] == "approved"
assert data["selection"]["durableGraphGate"] is True
assert data["selection"]["materializationPending"] is True
assert data["selection"]["selectedProposal"] is None
assert data["implementation"] is None
PY
expect_error GATE_ALREADY_DECIDED bash "$DESIGN_FLOW" reject --feature FS-0008 --json
expect_error OUTCOME_INCOMPLETE bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 \
  --lane design-lane --request-id partial-review --message "must remain blocked" --json

# Simulate an unrelated, valid graph revision between approval and retry. The
# selection append must use the new CAS revision while retaining gate history.
python3 - "$SNAPSHOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["revision"] += 1
value["eventCount"] += 1
value["updatedAt"] = "2026-07-22T00:00:59.000000Z"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

bash "$DESIGN_FLOW" select --feature FS-0008 --lane design-lane \
  --proposal proposal-b --json > "$TMP_ROOT/selected.json"
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "3"
unset DESIGN_SMOKE_FAIL_REPLACE_ONCE

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
assert status["selection"]["materializationPending"] is False
assert any("implementation" in item["nodeId"] for item in frontier["runnable"])
proposals = [item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "proposal"]
assert len(proposals) == 3 and all(item["state"] == "completed" for item in proposals)
implementation = next(item for item in snapshot["nodes"] if item.get("metadata",{}).get("designFlow",{}).get("role") == "implementation")
gate_edges = [item for item in snapshot["edges"] if item["kind"] == "gated-by" and item["from"] == implementation["id"]]
assert len(gate_edges) == 1 and gate_edges[0]["to"] == status["selection"]["gateNodeId"]
PY

# A selected implementation without its exact gated-by relationship is corrupt
# and must not trigger any further graph mutation on retry.
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
test "$(wc -l < "$GRAPH_LOG" | tr -d ' ')" = "3"
mv "$TMP_ROOT/missing-gate-backup.json" "$SNAPSHOT"

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

# Exercise the installed feedback owner itself, not the smoke shim. The owner
# takes the inherited root lock and then the descriptor-opened inbox lock.
# Holding the latter gives a deterministic post-validation swap point. It must
# refuse before publishing an FB record and must leave the replacement root
# byte-, metadata-, and topology-identical.
if [ -n "$installed_operator_dir" ]; then
  production_feedback_request="production-provider-swap-001"
  production_feedback_original="${OPERATOR_DIR}.production-feedback-original.$$"
  production_feedback_replacement="${OPERATOR_DIR}.production-feedback-replacement.$$"
  production_feedback_ready="$TMP_ROOT/production-feedback-inbox-held"
  production_feedback_release="$TMP_ROOT/production-feedback-inbox-release"
  production_feedback_error="$TMP_ROOT/production-feedback-swap.err"
  /usr/bin/python3 - "$OPERATOR_DIR/roadmap/inbox" "$production_feedback_ready" "$production_feedback_release" <<'PY' &
import fcntl, os, pathlib, sys, time
descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    deadline = time.monotonic() + 20
    while not pathlib.Path(sys.argv[3]).exists():
        if time.monotonic() >= deadline:
            raise SystemExit("timed out waiting to release production feedback inbox")
        time.sleep(0.01)
finally:
    fcntl.flock(descriptor, fcntl.LOCK_UN)
    os.close(descriptor)
PY
  production_feedback_locker_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$production_feedback_ready" ] && break
    sleep 0.01
  done
  test -e "$production_feedback_ready"
  mkdir -p "$production_feedback_replacement/graph" "$production_feedback_replacement/prompts" \
    "$production_feedback_replacement/roadmap/inbox"
  printf 'OPERATOR_PRODUCTION_FEEDBACK_REPLACEMENT_POISON\n' > "$production_feedback_replacement/graph/DO-NOT-READ"
  printf 'OPERATOR_PRODUCTION_FEEDBACK_REPLACEMENT_POISON\n' > "$production_feedback_replacement/prompts/design-proposal.md"
  production_feedback_graph_before="$(file_state "$GRAPH_LOG")"
  bash "$PRODUCTION_DESIGN_FLOW" dissatisfied --feature FS-0008 --lane design-lane \
    --request-id "$production_feedback_request" --message "Production provider root binding" \
    --evidence "$TMP_ROOT/evidence.txt" --json \
    > "$TMP_ROOT/production-feedback-swap.out" 2> "$production_feedback_error" &
  production_feedback_pid=$!
  wait_for_root_lock "$OPERATOR_DIR"
  mv "$OPERATOR_DIR" "$production_feedback_original"
  mv "$production_feedback_replacement" "$OPERATOR_DIR"
  production_feedback_replacement_before="$(tree_state "$OPERATOR_DIR")"
  touch "$production_feedback_release"
  wait "$production_feedback_locker_pid"
  set +e
  wait "$production_feedback_pid"
  production_feedback_rc=$?
  set -e
  production_feedback_replacement_after="$(tree_state "$OPERATOR_DIR")"
  mv "$OPERATOR_DIR" "$production_feedback_replacement"
  mv "$production_feedback_original" "$OPERATOR_DIR"
  test "$production_feedback_rc" -ne 0
  assert_root_identity_error "$production_feedback_error"
  test "$production_feedback_replacement_before" = "$production_feedback_replacement_after"
  test "$production_feedback_graph_before" = "$(file_state "$GRAPH_LOG")"
  test "$(find "$OPERATOR_DIR/roadmap/inbox" "$production_feedback_replacement/roadmap/inbox" \
    -type f -name 'FB-*-design-flow-*.md' | wc -l | tr -d ' ')" = "0"
  if rg -n 'OPERATOR_PRODUCTION_FEEDBACK_REPLACEMENT_POISON' "$OPERATOR_DIR"; then
    printf 'production feedback provider consumed replacement-root poison\n' >&2
    exit 1
  fi
  production_feedback_token="$(/usr/bin/python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$production_feedback_request")"
  rm -rf "$FEATURE_DIR/work/design-options/improvements/improvement-$production_feedback_token"
  rm -rf "$production_feedback_replacement"
fi

# Dissatisfaction reaches its trusted feedback owner only after evidence has
# been copied through the original feature descriptor. Pause that owner, swap
# the root, and require the inherited root contract to refuse before feedback
# or graph mutation. The partial artifacts must remain exclusively anchored to
# the original feature for an idempotent retry.
dissatisfied_swap_ready="$TMP_ROOT/dissatisfied-swap-ready"
dissatisfied_swap_go="$TMP_ROOT/dissatisfied-swap-go"
dissatisfied_swap_original="${OPERATOR_DIR}.dissatisfied-original.$$"
dissatisfied_swap_replacement="${OPERATOR_DIR}.dissatisfied-replacement.$$"
dissatisfied_snapshot_before="$(file_state "$SNAPSHOT")"
dissatisfied_graph_before="$(file_state "$GRAPH_LOG")"
mkdir -p "$dissatisfied_swap_replacement/graph" "$dissatisfied_swap_replacement/prompts"
printf 'OPERATOR_DISSATISFIED_ROOT_POISON\n' > "$dissatisfied_swap_replacement/graph/DO-NOT-READ"
printf 'OPERATOR_DISSATISFIED_ROOT_POISON\n' > "$dissatisfied_swap_replacement/prompts/design-proposal.md"
export DESIGN_SMOKE_FEEDBACK_READY="$dissatisfied_swap_ready"
export DESIGN_SMOKE_FEEDBACK_GO="$dissatisfied_swap_go"
bash "$DESIGN_FLOW" dissatisfied --feature FS-0008 --lane design-lane \
  --request-id review-001 --message "Needs a clearer hierarchy" \
  --evidence "$TMP_ROOT/evidence.txt" --json \
  > "$TMP_ROOT/dissatisfied-swap.out" 2> "$TMP_ROOT/dissatisfied-swap.err" &
dissatisfied_swap_pid=$!
for _ in $(seq 1 500); do
  [ -e "$dissatisfied_swap_ready" ] && break
  sleep 0.01
done
test -e "$dissatisfied_swap_ready"
test "$(find "$FEATURE_DIR/work/design-options/improvements" -name dissatisfaction.md | wc -l | tr -d ' ')" = "1"
mv "$OPERATOR_DIR" "$dissatisfied_swap_original"
mv "$dissatisfied_swap_replacement" "$OPERATOR_DIR"
touch "$dissatisfied_swap_go"
set +e
wait "$dissatisfied_swap_pid"
dissatisfied_swap_rc=$?
mv "$OPERATOR_DIR" "$dissatisfied_swap_replacement"
dissatisfied_replacement_restore_rc=$?
mv "$dissatisfied_swap_original" "$OPERATOR_DIR"
dissatisfied_original_restore_rc=$?
set -e
unset DESIGN_SMOKE_FEEDBACK_READY DESIGN_SMOKE_FEEDBACK_GO
test "$dissatisfied_swap_rc" -ne 0
test "$dissatisfied_replacement_restore_rc" -eq 0
test "$dissatisfied_original_restore_rc" -eq 0
assert_root_identity_error "$TMP_ROOT/dissatisfied-swap.err"
test "$dissatisfied_snapshot_before" = "$(file_state "$SNAPSHOT")"
test "$dissatisfied_graph_before" = "$(file_state "$GRAPH_LOG")"
test ! -e "$FEEDBACK_LOG"
test ! -e "$dissatisfied_swap_replacement/work"
test "$(find "$FEATURE_DIR/work/design-options/improvements" -name dissatisfaction.md | wc -l | tr -d ' ')" = "1"
if rg -n 'OPERATOR_DISSATISFIED_ROOT_POISON' "$OPERATOR_DIR"; then
  printf 'dissatisfied root-swap poison reached the original workspace\n' >&2
  exit 1
fi
rm -rf "$dissatisfied_swap_replacement"

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
    assert set(request) == {"schemaVersion","command","requestId","graphId","expectedRevision","cliIntent","definition","gateNodeId","decision"}
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
