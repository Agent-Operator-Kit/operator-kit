#!/usr/bin/env bash
set -euo pipefail

KIT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-design-production.XXXXXX)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
KEYCHAIN="$TMP_ROOT/design-proof-signer"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

repo="$TMP_ROOT/project/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
bash "$KIT_SOURCE/scripts/operator-bootstrap.sh" "$repo" >/dev/null
operator_dir="$TMP_ROOT/project/operator"
graph="$repo/scripts/operator-graph.sh"
design="$repo/scripts/operator-design-flow.sh"

cat > "$KEYCHAIN" <<'PY'
#!/usr/bin/python3
import base64, hashlib, json, sys
n=int("db69e0f76bb58ac09964d8a1e12d4a57a25e7165cb7cf59a95a4863fa8a297df2e10b3de56bcdaae20df6461c017b53a0b95025d93ce2915fc18b887c73628f1b6fe3106de12d788f498f3daf5d8087fe48080f501df5c36b5e7e409f5f95ce13019807cb7bb2f7b422a5284949a4c284c797a6479a97638031dcf39398c8067",16)
d=int("7c670dbc7aff558a59ee89bd4ed4c4ffe6f9b145cc182f90d423925269a4b6833db50ea6937b4469d20d96f6ad5943d1835b9b19bf81f65d96afd580767cc8bd26da0611cca73282da9402d58be9c1b737e2ec88e49b57132e978e5b34ac5d93b5acbde645ef01be52613c115a18cae32180c452f46c9fa35f490e5904795641",16)
value=json.load(sys.stdin); payload=value["payload"]
canonical=lambda item:(json.dumps(item,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
digest=bytes.fromhex("3031300d060960864801650304020105000420")+hashlib.sha256(canonical(payload)).digest()
width=(n.bit_length()+7)//8; encoded=b"\x00\x01"+b"\xff"*(width-len(digest)-3)+b"\x00"+digest
signature=base64.urlsafe_b64encode(pow(int.from_bytes(encoded,"big"),d,n).to_bytes(width,"big")).decode().rstrip("=")
response={"schemaVersion":"operator.proof-sign-response/v1","proofKeyId":value["proofKeyId"],"signature":signature}
sys.stdout.buffer.write(canonical(response))
PY
chmod 500 "$KEYCHAIN"

cat > "$TMP_ROOT/trusted-graph-setup.py" <<'PY'
import base64, hashlib, json, os, pathlib, socket, subprocess, sys

operator_dir, graph, keychain, mode, *arguments = sys.argv[1:]
root = pathlib.Path(operator_dir)
sys.path.insert(0, str(pathlib.Path(graph).parent))
import operator_graph

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

def receive_line(channel):
    data = bytearray()
    while not data.endswith(b"\n"):
        part = channel.recv(65536)
        if not part:
            return None
        data.extend(part)
    return json.loads(data)

def mutate(binding_id, args):
    broker, child = socket.socketpair()
    env = {"PATH":"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
           "LC_ALL":"C", "LANG":"C", "OPERATOR_DIR":operator_dir}
    process = subprocess.Popen([graph, *args, "--actor-binding", binding_id,
                                "--proof-fd", str(child.fileno())],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                               pass_fds=(child.fileno(),))
    child.close()
    for phase in ("authorize", "event"):
        challenge = receive_line(broker)
        if challenge is None:
            break
        assert challenge["phase"] == phase
        response = {"schemaVersion":"operator.proof-response/v1", "phase":phase,
                    "proofKeyId":challenge["proofKeyId"], "signature":sign(challenge["payload"])}
        broker.sendall(canonical(response))
        if phase == "event":
            broker.shutdown(socket.SHUT_WR)
    broker.close()
    output, error = process.communicate(timeout=30)
    if process.returncode != 0:
        raise SystemExit(error.decode() or output.decode())
    return json.loads(output)

if mode == "setup":
    authority = {"schemaVersion":"operator.authority-key/v1", "projectId":"design-production",
                 "graphId":"design-production", "keyId":"design-root-1",
                 "canonicalHostId":operator_graph.HOST_ID, "algorithm":"RS256",
                 "publicKey":{"n":format(n, "x"), "e":65537}}
    (root / "authority").mkdir(parents=True, exist_ok=True)
    (root / "graph" / "bindings").mkdir(parents=True, exist_ok=True)
    (root / "host").mkdir(parents=True, exist_ok=True)
    (root / "authority" / "control-graph-public-key.json").write_bytes(canonical(authority))
    bindings = {
        "design-operator": ({"type":"operator", "id":"design-operator"},
                            ["graph-init", "graph-replace", "transition"]),
        "design-human": ({"type":"human", "id":"design-human"}, ["gate-decision"]),
    }
    for binding_id, (subject, capabilities) in bindings.items():
        payload = {"schemaVersion":"operator.actor-binding/v1", "bindingId":binding_id, "generation":1,
                   "projectId":"design-production", "graphId":"design-production",
                   "issuedAt":"2020-01-01T00:00:00Z", "expiresAt":"2099-01-01T00:00:00Z",
                   "subject":subject, "capabilities":sorted(capabilities), "leaseScopes":[],
                   "proofKey":{"keyId":f"proof-{binding_id}-1", "algorithm":"RS256",
                               "publicKey":{"n":format(n, "x"), "e":65537}}}
        payload["signature"] = {"keyId":"design-root-1", "algorithm":"RS256", "value":sign(payload)}
        (root / "graph" / "bindings" / f"{binding_id}.json").write_bytes(canonical(payload))
    locator = {"schemaVersion":"operator.design-proof-signer/v1", "command":keychain}
    (root / "host" / "design-proof-signer.json").write_bytes(canonical(locator))
    definition = {"schemaVersion":"operator.control-graph/v1", "graphId":"design-production",
                  "nodes":[
                    {"id":"goal", "kind":"goal", "title":"Goal", "initialState":"planned", "priority":0, "metadata":{}},
                    {"id":"FS-9001", "kind":"feature", "title":"Production design", "initialState":"planned", "priority":0,
                     "metadata":{"featureSessionId":"FS-9001"}},
                    {"id":"design-lane", "kind":"lane", "title":"Design lane", "initialState":"planned", "priority":0, "metadata":{}},
                  ], "edges":[
                    {"id":"contains:goal:FS-9001", "kind":"contains", "from":"goal", "to":"FS-9001", "metadata":{}},
                    {"id":"contains:FS-9001:design-lane", "kind":"contains", "from":"FS-9001", "to":"design-lane", "metadata":{}},
                  ]}
    path = pathlib.Path(keychain).with_suffix(".definition.json")
    path.write_bytes(canonical(definition))
    mutate("design-operator", ["init", "--definition", str(path), "--request-id", "design-production-init"])
elif mode == "complete":
    for node_id in arguments:
        for state in ("ready", "active", "completed"):
            snapshot = json.loads(subprocess.check_output([graph, "snapshot"], env={
                "PATH":"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                "LC_ALL":"C", "LANG":"C", "OPERATOR_DIR":operator_dir}))
            mutate("design-operator", ["transition", node_id, state, "--request-id",
                   f"setup-{node_id}-{state}", "--expected-revision", str(snapshot["data"]["revision"])])
elif mode == "add-feature":
    snapshot = json.loads(subprocess.check_output([graph, "snapshot"], env={
        "PATH":"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "LC_ALL":"C", "LANG":"C", "OPERATOR_DIR":operator_dir}))["data"]
    definition = {"schemaVersion":"operator.control-graph/v1", "graphId":snapshot["graphId"],
                  "nodes":[{key:node[key] for key in ("id","kind","title","initialState","priority","metadata")}
                           for node in snapshot["nodes"]], "edges":snapshot["edges"]}
    definition["nodes"].extend((
        {"id":"FS-9002", "kind":"feature", "title":"Swap design", "initialState":"planned", "priority":0,
         "metadata":{"featureSessionId":"FS-9002"}},
        {"id":"swap-lane", "kind":"lane", "title":"Swap lane", "initialState":"planned", "priority":0, "metadata":{}},
    ))
    definition["edges"].extend((
        {"id":"contains:goal:FS-9002", "kind":"contains", "from":"goal", "to":"FS-9002", "metadata":{}},
        {"id":"contains:FS-9002:swap-lane", "kind":"contains", "from":"FS-9002", "to":"swap-lane", "metadata":{}},
    ))
    path = pathlib.Path(keychain).with_suffix(".feature.json")
    path.write_bytes(canonical(definition))
    mutate("design-operator", ["replace-definition", str(path), "--request-id", "setup-add-swap-feature",
                               "--expected-revision", str(snapshot["revision"])])
else:
    raise SystemExit(mode)
PY

/usr/bin/python3 -E -s "$TMP_ROOT/trusted-graph-setup.py" "$operator_dir" "$graph" "$KEYCHAIN" setup

# Exercise the installed graph Store as a descriptor-capability child. Every
# authority-bearing directory and leaf remains pinned across hostile
# substitutions, and lock release removes only the held production lock inode.
/usr/bin/python3 -E -s - "$operator_dir" "$repo/scripts" <<'PY'
import fcntl, hashlib, os, pathlib, shutil, stat, sys
root = pathlib.Path(sys.argv[1]); sys.path.insert(0, sys.argv[2])
import operator_graph as graph

root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(root_fd, fcntl.LOCK_EX)
root_info = os.fstat(root_fd)
class Guard:
    descriptor = root_fd
    path = root
    identity = (root_info.st_dev, root_info.st_ino)
    children = {}
    leaves = {}
    binding_manifest = {}
    authority_fd = os.open("authority", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
    graph_fd = os.open("graph", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
    bindings_fd = os.open("bindings", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=graph_fd)
    children.update(authority=authority_fd, graph=graph_fd, bindings=bindings_fd)
    for label, parent, name, flags in (
        ("authority/control-graph-public-key.json", authority_fd, "control-graph-public-key.json", os.O_RDONLY),
        ("graph/definition.json", graph_fd, "definition.json", os.O_RDONLY),
        ("graph/projection.json", graph_fd, "projection.json", os.O_RDONLY),
        ("graph/events.jsonl", graph_fd, "events.jsonl", os.O_RDWR),
    ):
        leaves[label] = os.open(name, flags | os.O_NOFOLLOW, dir_fd=parent)
    for name in os.listdir(bindings_fd):
        binding_leaf = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=bindings_fd)
        try:
            info = os.fstat(binding_leaf)
            data = os.pread(binding_leaf, info.st_size, 0)
            binding_manifest[name] = (info.st_dev, info.st_ino, info.st_size,
                                      hashlib.sha256(data).hexdigest())
        finally:
            os.close(binding_leaf)
    def verify_path(self):
        current = os.lstat(self.path)
        assert stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == self.identity

def swap_leaf(path, operation):
    held = path.with_name(path.name + ".held")
    poison = b'{"poison":true}\n'
    path.rename(held); path.write_bytes(poison)
    before = path.read_bytes()
    try:
        try: operation()
        except graph.GraphError as error: assert error.code in {"IO_ERROR", "AUTHORITY_DENIED", "CORRUPT_JOURNAL"}, error.code
        else: raise AssertionError(f"leaf swap was accepted: {path}")
        assert path.read_bytes() == before
    finally:
        path.unlink(); held.rename(path)

def swap_directory(path, operation):
    held = path.with_name(path.name + ".held")
    path.rename(held); path.mkdir(mode=0o700)
    marker = path / "shadow-must-survive"; marker.write_text("shadow\n")
    try:
        try: operation()
        except graph.GraphError as error: assert error.code in {"IO_ERROR", "LOCK_TIMEOUT"}, error.code
        else: raise AssertionError(f"directory swap was accepted: {path}")
        assert marker.read_text() == "shadow\n"
    finally:
        shutil.rmtree(path); held.rename(path)

store = graph.Store(pathlib.Path(".")); guard = Guard()
try:
    assert (os.fstat(guard.children["graph"]).st_dev, os.fstat(guard.children["graph"]).st_ino) == (
        os.stat("graph", dir_fd=root_fd, follow_symlinks=False).st_dev,
        os.stat("graph", dir_fd=root_fd, follow_symlinks=False).st_ino,
    )
    store.attach_trusted_root(guard)
    swap_leaf(root / "authority" / "control-graph-public-key.json", store.load_authority)
    swap_leaf(root / "graph" / "bindings" / "design-operator.json",
              lambda: store.read_binding("design-operator"))
    for name in ("events.jsonl", "definition.json", "projection.json"):
        with store.lock():
            swap_leaf(root / "graph" / name, lambda: store.load())
    swap_directory(root / "authority", store.load_authority)
    swap_directory(root / "graph" / "bindings", lambda: store.read_binding("design-operator"))
    swap_directory(root / "graph", lambda: store.lock().__enter__())

    # A completed A->B->A cycle cannot change the held read authority.
    authority = root / "authority" / "control-graph-public-key.json"
    held = authority.with_name(authority.name + ".aba")
    authority.rename(held); authority.write_text('{"poison":true}\n'); authority.unlink(); held.rename(authority)
    assert store.load_authority()["graphId"] == "design-production"

    with store.lock():
        swap_leaf(root / "graph" / "projection.json",
                  lambda: store.write_graph_json("projection.json", {"poison": True}))

    lock = store.lock(); lock.__enter__()
    original_lock = root / "graph" / ".lock"
    held_lock = root / "graph" / ".lock-held"
    original_lock.rename(held_lock); original_lock.mkdir(mode=0o700)
    shadow = original_lock / "shadow-must-survive"; shadow.write_text("shadow\n")
    try:
        try: lock.__exit__(None, None, None)
        except graph.GraphError as error: assert error.code == "LOCK_TIMEOUT", error.code
        else: raise AssertionError("interchanged graph lock release was accepted")
        assert shadow.read_text() == "shadow\n"
        assert not held_lock.exists(), "held production lock was left stale"
    finally:
        shutil.rmtree(original_lock)
finally:
    store.close()
    for descriptor in Guard.leaves.values(): os.close(descriptor)
    for descriptor in Guard.children.values(): os.close(descriptor)
    os.close(root_fd)
PY

# Exercise the installed production provider/result/replay path at the exact
# post-provider, pre-refresh boundary.  The pause exists only in a copied test
# launcher; the shipped entrypoint has no caller-controlled test-mode escape.
post_mutation_tamper_case() {
  local mode="$1"
  local case_root="$TMP_ROOT/post-mutation-$mode"
  local case_repo="$case_root/project/code/app"
  local case_operator="$case_root/project/operator"
  local case_graph="$case_repo/scripts/operator-graph.sh"
  local case_design="$case_repo/scripts/operator-design-flow.sh"
  local tamper_design="$case_repo/scripts/operator-design-flow-post-mutation-test.sh"
  local ready="$case_root/provider-success-ready"
  local release="$case_root/provider-success-release"
  local output="$case_root/design.out"
  local error="$case_root/design.err"
  local pre_journal="$case_root/events-before-mutation.jsonl"

  mkdir -p "$case_repo"
  git -C "$case_repo" init -b main >/dev/null
  bash "$KIT_SOURCE/scripts/operator-bootstrap.sh" "$case_repo" >/dev/null
  /usr/bin/python3 -E -s "$TMP_ROOT/trusted-graph-setup.py" \
    "$case_operator" "$case_graph" "$KEYCHAIN" setup
  mkdir -p "$case_operator/features/FS-9001-production-design"
  printf '{"id":"FS-9001","slug":"production-design"}\n' \
    > "$case_operator/features/FS-9001-production-design/status.json"
  printf '# Post-mutation tamper brief\n\nExercise unconditional refresh.\n' \
    > "$case_root/brief.md"
  cp "$case_operator/graph/events.jsonl" "$pre_journal"
  cp "$case_design" "$tamper_design"
  /usr/bin/python3 -E -s - "$tamper_design" "$ready" "$release" <<'PY'
from pathlib import Path
import sys

launcher, ready, release = map(Path, sys.argv[1:])
source = launcher.read_text(encoding="utf-8")
needle = "    root.refresh_mutable_graph_leaves(request_id, expected_revision + 1)\n"
assert source.count(needle) == 1
pause = (
    f"    Path({str(ready)!r}).touch()\n"
    f"    while not Path({str(release)!r}).exists():\n"
    "        time.sleep(0.01)\n"
)
launcher.write_text(source.replace(needle, pause + needle), encoding="utf-8")
PY
  chmod 755 "$tamper_design"

  env -u OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND \
      -u OPERATOR_DESIGN_FLOW_MUTATION_COMMAND \
      -u OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND \
      -u OPERATOR_DESIGN_FLOW_GRAPH_MUTATION_HOST_COMMAND \
      OPERATOR_DIR="$case_operator" bash "$tamper_design" start \
      --feature FS-9001 --brief "$case_root/brief.md" --lane design-lane \
      --title "Post-mutation tamper" --json > "$output" 2> "$error" &
  local design_pid=$!
  local reached=0
  local attempt
  for attempt in $(seq 1 2000); do
    if [ -e "$ready" ]; then
      reached=1
      break
    fi
    if ! kill -0 "$design_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  if [ "$reached" -ne 1 ]; then
    kill "$design_pid" 2>/dev/null || true
    wait "$design_pid" 2>/dev/null || true
    cat "$error" >&2
    printf 'post-mutation pause was not reached for %s\n' "$mode" >&2
    return 1
  fi
  kill -0 "$design_pid"

  case "$mode" in
    journal-append)
      /usr/bin/python3 -E -s - "$case_operator/graph/events.jsonl" <<'PY'
import os, sys
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
try:
    before = os.fstat(fd)
    os.write(fd, b'{"poison":true}\n')
    os.fsync(fd)
    after = os.fstat(fd)
    assert (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)
finally:
    os.close(fd)
PY
      ;;
    journal-truncate-restore)
      /usr/bin/python3 -E -s - "$case_operator/graph/events.jsonl" "$pre_journal" <<'PY'
import os, pathlib, sys
path, prior = sys.argv[1:]
old = pathlib.Path(prior).read_bytes()
fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
try:
    before = os.fstat(fd)
    offset = 0
    while offset < len(old):
        offset += os.write(fd, old[offset:])
    os.fsync(fd)
    after = os.fstat(fd)
    assert (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)
    assert after.st_size == len(old)
finally:
    os.close(fd)
PY
      ;;
    definition-replace|projection-replace)
      local leaf="${mode%-replace}.json"
      /usr/bin/python3 -E -s - "$case_operator/graph/$leaf" <<'PY'
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
held = path.with_name(path.name + ".committed")
path.rename(held)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.write(fd, b'{"poison":true}\n')
    os.fsync(fd)
finally:
    os.close(fd)
assert path.read_bytes() == b'{"poison":true}\n'
PY
      ;;
    *)
      printf 'unknown post-mutation tamper case: %s\n' "$mode" >&2
      return 1
      ;;
  esac

  touch "$release"
  local design_rc
  set +e
  wait "$design_pid"
  design_rc=$?
  set -e
  test "$design_rc" -ne 0
  test ! -s "$output"
  rg -q 'IO_ERROR|INTERFACE_PROTOCOL|CORRUPT_JOURNAL|REPLAY_DRIFT|post-mutation' "$error" || {
    cat "$error" >&2
    return 1
  }
  if [ "$mode" = definition-replace ] || [ "$mode" = projection-replace ]; then
    local leaf="${mode%-replace}.json"
    test "$(cat "$case_operator/graph/$leaf")" = '{"poison":true}'
  fi
}

post_mutation_tamper_case journal-append
post_mutation_tamper_case journal-truncate-restore
post_mutation_tamper_case definition-replace
post_mutation_tamper_case projection-replace

feature_dir="$operator_dir/features/FS-9001-production-design"
mkdir -p "$feature_dir"
printf '{"id":"FS-9001","slug":"production-design"}\n' > "$feature_dir/status.json"
printf '# Production design brief\n\nExercise the installed authority boundary.\n' > "$TMP_ROOT/brief.md"

run_design() {
  env -u OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND \
      -u OPERATOR_DESIGN_FLOW_MUTATION_COMMAND \
      -u OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND \
      -u OPERATOR_DESIGN_FLOW_GRAPH_MUTATION_HOST_COMMAND \
      OPERATOR_DIR="$operator_dir" bash "$design" "$@"
}

# The installed entrypoint owns all three production provider selections.
# Caller command overrides are rejected before a provider can execute or any
# graph state can change.
override_provider="$TMP_ROOT/hostile-provider"
override_marker="$TMP_ROOT/hostile-provider-executed"
cat > "$override_provider" <<SH
#!/bin/sh
touch '$override_marker'
exit 0
SH
chmod 500 "$override_provider"
override_revision="$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
for override_name in OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND \
  OPERATOR_DESIGN_FLOW_MUTATION_COMMAND OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND \
  OPERATOR_DESIGN_FLOW_GRAPH_MUTATION_HOST_COMMAND; do
  set +e
  env "$override_name=$override_provider" OPERATOR_DIR="$operator_dir" \
    bash "$design" status --feature FS-9001 --json \
    > "$TMP_ROOT/override-$override_name.out" 2> "$TMP_ROOT/override-$override_name.err"
  override_rc=$?
  set -e
  test "$override_rc" -ne 0
  rg -q 'AUTHORITY_DENIED|rejects trusted-provider command overrides' \
    "$TMP_ROOT/override-$override_name.err"
  test ! -e "$override_marker"
done
test "$override_revision" = "$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"

write_signer_locator() {
  /usr/bin/python3 -E -s - "$operator_dir" "$1" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); command=sys.argv[2]
value={"schemaVersion":"operator.design-proof-signer/v1","command":command}
(root/"host"/"design-proof-signer.json").write_bytes(
    (json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode())
PY
}

# A configured proof provider is a separate production authority boundary. A
# signer physically contained by either the held external Operator workspace or
# the installed repository/worktree must be refused before execution, proof,
# or graph mutation even when the leaf itself has otherwise safe metadata.
containment_revision="$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
for contained_signer in "$operator_dir/host/operator-local-signer" "$repo/repo-local-signer"; do
  contained_marker="$contained_signer.executed"
  /usr/bin/python3 -E -s - "$contained_signer" "$contained_marker" "$KEYCHAIN" <<'PY'
import pathlib, shlex, sys
destination=pathlib.Path(sys.argv[1])
destination.write_text("#!/bin/sh\ntouch " + shlex.quote(sys.argv[2]) + "\nexec "
                       + shlex.quote(sys.argv[3]) + "\n", encoding="utf-8")
destination.chmod(0o500)
PY
  write_signer_locator "$contained_signer"
  set +e
  run_design start --feature FS-9001 --brief "$TMP_ROOT/brief.md" --lane design-lane \
    --title "Production path" --json > "$contained_signer.out" 2> "$contained_signer.err"
  contained_rc=$?
  set -e
  test "$contained_rc" -ne 0
  test ! -e "$contained_marker"
  rg -q 'BROKER_UNAVAILABLE|must be outside OPERATOR_DIR|must be outside the project' \
    "$contained_signer.err" || { cat "$contained_signer.err" >&2; exit 1; }
  containment_revision_after="$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
  test "$containment_revision" = "$containment_revision_after"
done

hardlink_external="$TMP_ROOT/hardlink-external-signer"
hardlink_alias="$repo/repo-hardlink-signer-alias"
hardlink_marker="$TMP_ROOT/hardlink-signer-executed"
/usr/bin/python3 -E -s - "$hardlink_external" "$hardlink_marker" "$KEYCHAIN" <<'PY'
import pathlib, shlex, sys
destination=pathlib.Path(sys.argv[1])
destination.write_text("#!/bin/sh\ntouch " + shlex.quote(sys.argv[2]) + "\nexec "
                       + shlex.quote(sys.argv[3]) + "\n", encoding="utf-8")
destination.chmod(0o500)
PY
if ln "$hardlink_external" "$hardlink_alias" 2>/dev/null; then
  write_signer_locator "$hardlink_external"
  set +e
  run_design start --feature FS-9001 --brief "$TMP_ROOT/brief.md" --lane design-lane \
    --title "Production path" --json > "$TMP_ROOT/hardlink.out" 2> "$TMP_ROOT/hardlink.err"
  hardlink_rc=$?
  set -e
  test "$hardlink_rc" -ne 0
  test ! -e "$hardlink_marker"
  rg -q 'BROKER_UNAVAILABLE|signer executable is unsafe' "$TMP_ROOT/hardlink.err"
  hardlink_revision_after="$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
  test "$containment_revision" = "$hardlink_revision_after"
fi
write_signer_locator "$KEYCHAIN"

cat > "$TMP_ROOT/direct-design-provider.py" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root, launcher = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(launcher.parent))
import operator_host as host
store = host.AnchoredStore(root, acquire_exclusive=True, initialize_capability=True)
manifest = tempfile.TemporaryFile()
try:
    entries = []
    for parts, record in sorted(store.file_manifest.items()):
        if parts[:2] != ("graph", "bindings") or len(parts) != 3:
            continue
        entries.append({"name": parts[2], "dev": record[0], "ino": record[1],
                        "size": record[2], "sha256": record[3]})
    manifest.write(host.canonical({"schemaVersion":"operator.binding-capability-manifest/v1",
                                   "entries":entries}))
    manifest.flush(); manifest.seek(0)
    info = os.fstat(store.root_fd)
    environment = {"PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "HOME":os.environ["HOME"],
                   "TMPDIR":os.environ.get("TMPDIR", "/tmp"), "OPERATOR_DIR":str(root),
                   "OPERATOR_DESIGN_FLOW_PROVIDER_MODE":"mutation",
                   "OPERATOR_DESIGN_FLOW_ROOT_FD":str(store.root_fd),
                   "OPERATOR_DESIGN_FLOW_ROOT_DEV":str(info.st_dev),
                   "OPERATOR_DESIGN_FLOW_ROOT_INO":str(info.st_ino),
                   "OPERATOR_DESIGN_FLOW_ROOT_PATH":str(root),
                   "OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE":"exclusive-held"}
    caps, descriptors = host.capability_environment("OPERATOR_DESIGN_FLOW_ROOT", store)
    environment.update(caps)
    environment["OPERATOR_DESIGN_FLOW_ROOT_BINDING_MANIFEST_FD"] = str(manifest.fileno())
    completed = subprocess.run([str(launcher)], input=sys.stdin.buffer.read(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment,
                               pass_fds=(*descriptors, manifest.fileno()), check=False)
    sys.stdout.buffer.write(completed.stdout); sys.stderr.buffer.write(completed.stderr)
    raise SystemExit(completed.returncode)
finally:
    manifest.close(); store.close()
PY

# Hostile direct start deltas must be refused before a proof broker can sign.
/usr/bin/python3 -E -s - "$operator_dir" "$repo/scripts/operator-graph.sh" "$TMP_ROOT/direct-design-provider.py" <<'PY'
import json, os, pathlib, subprocess, sys
root, launcher, helper = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
snapshot = json.loads(subprocess.check_output([launcher, "snapshot"], env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "OPERATOR_DIR":str(root)}))["data"]
definition = {"schemaVersion":"operator.control-graph/v1", "graphId":snapshot["graphId"],
              "nodes":[{k:n[k] for k in ("id","kind","title","initialState","priority","metadata")} for n in snapshot["nodes"]],
              "edges":snapshot["edges"]}
definition["nodes"].append({"id":"arbitrary-authority", "kind":"task", "title":"Arbitrary", "initialState":"pending", "priority":0, "metadata":{}})
request = {"schemaVersion":"operator.design-flow-graph-mutation-request/v1", "command":"replace-definition",
           "requestId":"design-start-FS-9001-design", "graphId":snapshot["graphId"],
           "expectedRevision":snapshot["revision"], "cliIntent":{"action":"start","featureId":"FS-9001","flowId":"design"},
           "definition":definition, "gateNodeId":None, "decision":None}
completed = subprocess.run([sys.executable, "-E", "-s", helper, str(root), launcher],
                           input=(json.dumps(request, sort_keys=True, separators=(",", ":"))+"\n").encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert completed.returncode != 0
error = json.loads(completed.stderr)
assert error["error"]["code"] == "AUTHORITY_DENIED", error
PY

run_design start --feature FS-9001 --brief "$TMP_ROOT/brief.md" --lane design-lane \
  --title "Production path" --json > "$TMP_ROOT/start.json"
proposals="$(/usr/bin/python3 - "$TMP_ROOT/start.json" <<'PY'
import json, sys
print(" ".join(item["nodeId"] for item in json.load(open(sys.argv[1]))["data"]["proposals"]))
PY
)"

# Direct early-gate bypass is refused while proposals are incomplete.
/usr/bin/python3 -E -s - "$operator_dir" "$repo/scripts/operator-graph.sh" "$TMP_ROOT/start.json" "$TMP_ROOT/direct-design-provider.py" <<'PY'
import json, os, pathlib, subprocess, sys
root, launcher, helper = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[4]
status = json.load(open(sys.argv[3]))["data"]
request = {"schemaVersion":"operator.design-flow-graph-mutation-request/v1", "command":"gate decide",
 "requestId":"design-select-gate-FS-9001-design-proposal-a", "graphId":status["graphId"],
 "expectedRevision":status["revision"], "cliIntent":{"action":"select","featureId":"FS-9001","flowId":"design","proposal":"proposal-a"},
 "definition":None, "gateNodeId":status["selection"]["gateNodeId"], "decision":"approved"}
p=subprocess.run([sys.executable,"-E","-s",helper,str(root),launcher],
 input=(json.dumps(request,sort_keys=True,separators=(",",":"))+"\n").encode(),
 stdout=subprocess.PIPE,stderr=subprocess.PIPE)
assert p.returncode != 0 and json.loads(p.stderr)["error"]["code"] == "AUTHORITY_DENIED", p.stderr
PY

# Node IDs are contract-safe single shell words.
# shellcheck disable=SC2086
/usr/bin/python3 -E -s "$TMP_ROOT/trusted-graph-setup.py" "$operator_dir" "$graph" "$KEYCHAIN" complete $proposals
run_design select --feature FS-9001 --lane design-lane --proposal proposal-a --json > "$TMP_ROOT/select.json"
implementation="$(/usr/bin/python3 - "$TMP_ROOT/select.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["data"]["implementation"]["nodeId"])
PY
)"
/usr/bin/python3 -E -s "$TMP_ROOT/trusted-graph-setup.py" "$operator_dir" "$graph" "$KEYCHAIN" complete "$implementation"

printf '# Existing non-design feedback\n\n- ID: FB-10000\n' > "$operator_dir/roadmap/inbox/FB-10000-existing.md"
printf 'installed evidence\n' > "$TMP_ROOT/evidence.txt"
run_design dissatisfied --feature FS-9001 --lane design-lane --request-id production-review-1 \
  --message "Refine the installed path" --evidence "$TMP_ROOT/evidence.txt" --json > "$TMP_ROOT/feedback.json"
/usr/bin/python3 - "$TMP_ROOT/feedback.json" "$operator_dir" <<'PY'
import json, pathlib, sys
data=json.load(open(sys.argv[1]))["data"]
assert data["improvements"][0]["feedbackId"] == "FB-10001", data
matches=list((pathlib.Path(sys.argv[2])/"roadmap"/"inbox").glob("FB-10001-design-flow-*.md"))
assert len(matches)==1
PY

# Exercise a deterministic post-snapshot/post-prompt swap through the installed
# production snapshot, mutation adapter, proof broker, and graph runtime. The
# watcher claims the real graph lock while proposal artifacts are still being
# written, giving the graph child a stable pre-commit pause without provider
# overrides or test hooks.
/usr/bin/python3 -E -s "$TMP_ROOT/trusted-graph-setup.py" "$operator_dir" "$graph" "$KEYCHAIN" add-feature
swap_feature="$operator_dir/features/FS-9002-swap-design"
mkdir -p "$swap_feature"
printf '{"id":"FS-9002","slug":"swap-design"}\n' > "$swap_feature/status.json"
printf '# Swap brief\n\nProve the held production root.\n' > "$TMP_ROOT/swap-brief.md"
swap_revision_before="$(OPERATOR_DIR="$operator_dir" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
swap_ready="$TMP_ROOT/swap-lock-ready"
swap_release="$TMP_ROOT/swap-lock-release"
(
  while [ ! -f "$swap_feature/work/design-options/proposal-a/prompt.md" ]; do sleep 0.005; done
  mkdir "$operator_dir/graph/.lock"
  printf 'held after production prompt\n' > "$operator_dir/graph/.lock/unexpected"
  touch "$swap_ready"
  while [ ! -e "$swap_release" ]; do sleep 0.01; done
) &
watcher_pid=$!
run_design start --feature FS-9002 --brief "$TMP_ROOT/swap-brief.md" --lane swap-lane \
  --title "Swap path" --json > "$TMP_ROOT/swap.out" 2> "$TMP_ROOT/swap.err" &
swap_pid=$!
for _ in $(seq 1 1000); do
  [ -e "$swap_ready" ] && break
  sleep 0.01
done
test -e "$swap_ready"
kill -0 "$swap_pid"
original_root="${operator_dir}.held-original"
replacement_root="${operator_dir}.poison-replacement"
mkdir -p "$replacement_root/graph" "$replacement_root/prompts"
printf 'PRODUCTION_ROOT_SWAP_POISON\n' > "$replacement_root/graph/poison"
printf 'PRODUCTION_ROOT_SWAP_POISON\n' > "$replacement_root/prompts/design-proposal.md"
mv "$operator_dir" "$original_root"
mv "$replacement_root" "$operator_dir"
replacement_before="$(/usr/bin/python3 - "$operator_dir" <<'PY'
import hashlib, os, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); records=[]
for current, dirs, files in os.walk(root, followlinks=False):
    dirs.sort(); files.sort()
    for name in dirs+files:
        path=pathlib.Path(current)/name; info=os.lstat(path); rel=str(path.relative_to(root))
        digest="-"
        if stat.S_ISREG(info.st_mode): digest=hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISLNK(info.st_mode): digest="link:"+os.readlink(path)
        records.append((rel,stat.S_IFMT(info.st_mode),stat.S_IMODE(info.st_mode),info.st_size,info.st_mtime_ns,digest))
print(repr(records))
PY
)"
rm "$original_root/graph/.lock/unexpected"
rmdir "$original_root/graph/.lock"
touch "$swap_release"
wait "$watcher_pid"
set +e
wait "$swap_pid"
swap_rc=$?
set -e
replacement_after="$(/usr/bin/python3 - "$operator_dir" <<'PY'
import hashlib, os, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); records=[]
for current, dirs, files in os.walk(root, followlinks=False):
    dirs.sort(); files.sort()
    for name in dirs+files:
        path=pathlib.Path(current)/name; info=os.lstat(path); rel=str(path.relative_to(root))
        digest="-"
        if stat.S_ISREG(info.st_mode): digest=hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISLNK(info.st_mode): digest="link:"+os.readlink(path)
        records.append((rel,stat.S_IFMT(info.st_mode),stat.S_IMODE(info.st_mode),info.st_size,info.st_mtime_ns,digest))
print(repr(records))
PY
)"
test "$swap_rc" -ne 0
test "$replacement_before" = "$replacement_after"
rg -q 'IO_ERROR|OPERATOR_DIR identity changed' "$TMP_ROOT/swap.err"
swap_revision_after="$(OPERATOR_DIR="$original_root" bash "$graph" snapshot | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["revision"])')"
test "$swap_revision_before" = "$swap_revision_after"
if rg -n 'PRODUCTION_ROOT_SWAP_POISON' "$original_root"; then
  printf 'production provider consumed replacement-root poison\n' >&2
  exit 1
fi
mv "$operator_dir" "$replacement_root"
mv "$original_root" "$operator_dir"
rm -rf "$replacement_root"

# The authority-adjacent launcher must ignore all Python startup and PATH poison.
mkdir -p "$TMP_ROOT/poison"
printf 'raise SystemExit("DESIGN_PYTHONPATH_POISON")\n' > "$TMP_ROOT/poison/json.py"
cat > "$TMP_ROOT/poison/python3" <<'SH'
#!/bin/sh
printf 'DESIGN_PATH_POISON\n' >> "$DESIGN_POISON_MARKER"
exit 97
SH
chmod +x "$TMP_ROOT/poison/python3"
DESIGN_POISON_MARKER="$TMP_ROOT/poison-hit" PYTHONPATH="$TMP_ROOT/poison" \
PYTHONHOME="$TMP_ROOT/does-not-exist" PATH="$TMP_ROOT/poison:/usr/bin:/bin" \
  run_design status --feature FS-9001 --json > "$TMP_ROOT/isolated-status.json"
test ! -e "$TMP_ROOT/poison-hit"
/usr/bin/python3 - "$TMP_ROOT/isolated-status.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["ok"] is True
PY

# The supported external proof-provider boundary executes an immutable snapshot
# of the held, verified signer descriptor.  Prove pathname replacement cannot
# execute a decoy, non-exact output is rejected, and a hung provider is killed
# at the production deadline.
/usr/bin/python3 -E -s - "$repo/scripts" "$TMP_ROOT" "$KEYCHAIN" <<'PY'
import json, os, pathlib, sys, threading, time
sys.path.insert(0, sys.argv[1])
import operator_host

temporary = pathlib.Path(sys.argv[2])
valid_signer = pathlib.Path(sys.argv[3])
binding = {"proofKey":{"keyId":"proof-design-operator-1","algorithm":"RS256","publicKey":{
    "n":"db69e0f76bb58ac09964d8a1e12d4a57a25e7165cb7cf59a95a4863fa8a297df2e10b3de56bcdaae20df6461c017b53a0b95025d93ce2915fc18b887c73628f1b6fe3106de12d788f498f3daf5d8087fe48080f501df5c36b5e7e409f5f95ce13019807cb7bb2f7b422a5284949a4c284c797a6479a97638031dcf39398c8067",
    "e":65537}}}
payload = {"schemaVersion":"operator.external-signer-smoke/v1","requestId":"signer-boundary"}

def signer_case(name, body):
    command = temporary / (name + "-provider")
    command.write_text(body, encoding="utf-8")
    command.chmod(0o500)
    root = temporary / (name + "-root")
    (root / "host").mkdir(parents=True)
    (root / "authority").mkdir()
    (root / "graph" / "bindings").mkdir(parents=True)
    (root / "authority" / "control-graph-public-key.json").write_text("{}\n", encoding="utf-8")
    locator = {"schemaVersion":"operator.design-proof-signer/v1","command":str(command)}
    (root / "host" / "design-proof-signer.json").write_bytes(operator_host.canonical(locator))
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        prior = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_PATH")
        os.environ["OPERATOR_DESIGN_FLOW_ROOT_PATH"] = str(root)
        try:
            callback = operator_host.design_external_signer(descriptor)
        finally:
            if prior is None: os.environ.pop("OPERATOR_DESIGN_FLOW_ROOT_PATH", None)
            else: os.environ["OPERATOR_DESIGN_FLOW_ROOT_PATH"] = prior
    finally:
        os.close(descriptor)
    assert callback is not None
    return command, callback

extra_command, extra = signer_case("extra", "#!/bin/sh\n" + str(valid_signer) + "\nprintf 'EXTRA\\n'\n")
try:
    extra(payload, binding)
    raise AssertionError("external signer extra output was accepted")
except operator_host.HostError as exc:
    assert exc.code == "BROKER_UNAVAILABLE", exc.code

overflow_command, overflow = signer_case(
    "overflow",
    "#!/bin/sh\n/usr/bin/python3 -c 'import sys,time;sys.stdout.write(\"X\"*5000);sys.stdout.flush();time.sleep(30)'\n",
)
started = time.monotonic()
try:
    overflow(payload, binding)
    raise AssertionError("external signer live over-output was accepted")
except operator_host.HostError as exc:
    assert exc.code == "BROKER_UNAVAILABLE" and "live bound" in exc.message, (exc.code, exc.message)
assert time.monotonic() - started < 5

content_poison = temporary / "signer-content-poison"
content_command, content = signer_case("content", "#!/bin/sh\nexec " + str(valid_signer) + "\n")
content_command.chmod(0o700)
descriptor = os.open(content_command, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
try:
    os.write(descriptor, ("#!/bin/sh\ntouch " + str(content_poison) + "\nexec "
                          + str(valid_signer) + "\n").encode())
    os.fsync(descriptor)
finally:
    os.close(descriptor)
content_command.chmod(0o500)
try:
    content(payload, binding)
    raise AssertionError("external signer in-place content swap was accepted")
except operator_host.HostError as exc:
    assert exc.code == "BROKER_UNAVAILABLE" and "content changed" in exc.message, (exc.code, exc.message)
assert not content_poison.exists(), "modified signer executable was consumed"

timeout_command, timeout = signer_case("timeout", "#!/bin/sh\nsleep 30\n")
started = time.monotonic()
try:
    timeout(payload, binding)
    raise AssertionError("external signer timeout was accepted")
except operator_host.HostError as exc:
    assert exc.code == "BROKER_UNAVAILABLE" and "timed out" in exc.message, (exc.code, exc.message)
assert 9 <= time.monotonic() - started < 15

ready = temporary / "signer-swap-ready"
release = temporary / "signer-swap-release"
poison = temporary / "signer-swap-poison"
swap_body = ("#!/bin/sh\ntouch " + str(ready) + "\n"
             "while [ ! -e " + str(release) + " ]; do sleep 0.01; done\n"
             "exec " + str(valid_signer) + "\n")
swap_command, swap = signer_case("swap", swap_body)
observed = {}
def invoke():
    try:
        observed["signature"] = swap(payload, binding)
    except BaseException as exc:
        observed["error"] = exc
thread = threading.Thread(target=invoke)
thread.start()
deadline = time.monotonic() + 5
while not ready.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
assert ready.exists(), "external signer swap pause was not reached"
swap_command.rename(swap_command.with_suffix(".held"))
swap_command.write_text("#!/bin/sh\ntouch " + str(poison) + "\nexec " + str(valid_signer) + "\n", encoding="utf-8")
swap_command.chmod(0o500)
release.touch()
thread.join(15)
assert not thread.is_alive()
assert "signature" not in observed
assert isinstance(observed.get("error"), operator_host.HostError)
assert observed["error"].code == "BROKER_UNAVAILABLE", observed["error"].code
assert not poison.exists(), "replacement signer executable was consumed"
PY

printf 'v5 installed production design provider smoke ok\n'
