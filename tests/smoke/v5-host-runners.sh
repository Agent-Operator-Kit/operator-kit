#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

TEST_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIT_ROOT="${OPERATOR_KIT_TEST_ROOT:-$TEST_SOURCE_ROOT}"
TMP_ROOT="$(mktemp -d "$KIT_ROOT/.aok-v5-host.XXXXXX")"
sandbox_survivor_pid=""
sandbox_survivor_start=""
network_server_pid=""
cleanup() {
  if [ -n "$network_server_pid" ]; then
    kill "$network_server_pid" 2>/dev/null || true
  fi
  if [ -n "$sandbox_survivor_pid" ] && [ -n "$sandbox_survivor_start" ]; then
    current_start="$(ps -p "$sandbox_survivor_pid" -o lstart= 2>/dev/null || true)"
    if [ "$current_start" = "$sandbox_survivor_start" ]; then
      kill -KILL "$sandbox_survivor_pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

RUNTIME="$TMP_ROOT/runtime"
STATE="$TMP_ROOT/operator"
CODE="$TMP_ROOT/code"
mkdir -m 700 -p "$RUNTIME" "$STATE/authority" "$STATE/graph/bindings" "$CODE/lane-a" "$CODE/lane-b"
cp "$KIT_ROOT/scripts/operator-host.sh" "$RUNTIME/operator-host.sh"
cp "$KIT_ROOT/scripts/operator-proof-broker.sh" "$RUNTIME/operator-proof-broker.sh"
cp "$KIT_ROOT/scripts/operator_host.py" "$RUNTIME/operator_host.py"
chmod 700 "$RUNTIME"/* "$STATE/authority" "$STATE/graph" "$STATE/graph/bindings"

for lane in lane-a lane-b; do
  git -C "$CODE/$lane" init -b "$lane" >/dev/null
  git -C "$CODE/$lane" config user.email smoke@example.com
  git -C "$CODE/$lane" config user.name "Smoke Test"
  printf '%s\n' "$lane" > "$CODE/$lane/README.md"
  git -C "$CODE/$lane" add README.md
  git -C "$CODE/$lane" commit -m init >/dev/null
done

cat > "$TMP_ROOT/operator.config.env" <<EOF
PROJECT_NAME="host-smoke"
PROJECT_ROOT="$TMP_ROOT"
CODE_DIR="$CODE"
OPERATOR_DIR="$STATE"
TMUX_SESSION="host-smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5"
OPERATOR_LANES='
lane-a|Codex CLI|lane-a|lane-a|codex --sandbox workspace-write
lane-b|Claude Code|lane-b|lane-b|claude --permission-mode dontAsk
'
EOF
chmod 600 "$TMP_ROOT/operator.config.env"

cat > "$RUNTIME/operator_graph.py" <<'PY'
import contextlib
import datetime as dt
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

# Exercise the same ambient-name resolution used by the production graph
# runtime's boot_id/process_start helpers. The trusted shell launcher must
# replace a caller-supplied PATH before this sibling module is imported.
for command in (["sysctl", "-n", "kern.boottime"],
                ["ps", "-o", "lstart=", "-p", str(os.getpid())]):
    try:
        subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
    except OSError:
        pass

HOST_ID = "host-smoke-host"
BOOT_ID = "host-smoke-boot"

def utc_now(): return dt.datetime.now(dt.timezone.utc)
def parse_time(value, _code="AUTHORITY_DENIED"): return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
def host_monotonic_sample():
    root = Path(os.environ.get("OPERATOR_DIR", "."))
    if os.environ.get("OPERATOR_HOST_INTERFACE_POLICY_FD", "").isdigit() \
            and (root / "block-relay-clock").exists():
        code = """import fcntl, os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
lock_fd = os.open(root / 'blocked-relay-child.lock', os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
(root / 'blocked-relay-child.pid').write_text(str(os.getpid()) + '\\n')
(root / 'blocked-relay-child-ready').write_text('ready\\n')
time.sleep(3600)
(root / 'blocked-relay-child-finished').write_text('finished\\n')
"""
        subprocess.run([sys.executable, "-c", code, str(root)],
                       start_new_session=True, check=False)
    return "macos-mach-continuous", time.monotonic_ns()
def validate_authority(value): return value
def validate_binding(value, binding_id, _authority):
    assert value["bindingId"] == binding_id
    return value
def sha256_value(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(raw).hexdigest()
def validate_authorization_payload(value, _code):
    assert set(value) == {"schemaVersion", "command", "requestId", "bindingId", "bindingGeneration",
                          "bindingHash", "intent", "expectedRevision"}
def actor_record(binding):
    return {"type": binding["subject"]["type"], "id": binding["subject"]["id"],
            "bindingId": binding["bindingId"], "bindingGeneration": binding["generation"],
            "bindingHash": binding["bindingHash"], "capabilityHash": binding["capabilityHash"],
            "projectId": binding["projectId"], "graphId": binding["graphId"],
            "issuedAt": binding["issuedAt"], "expiresAt": binding["expiresAt"],
            "keyId": binding["keyId"], "signature": binding["signature"],
            "capabilities": binding["capabilities"], "subject": binding["subject"],
            "leaseScopes": binding["leaseScopes"], "proofKey": binding["proofKey"],
            "authorityHash": binding["authorityHash"]}
def validate_actor_record(actor, _code): assert isinstance(actor, dict)
def validate_lease(lease, _code="AUTHORITY_DENIED"): assert isinstance(lease, dict)

class Store:
    def __init__(self, root): self.root = Path(root)
    @contextlib.contextmanager
    def lock(self): yield
    def load(self):
        value = json.loads((self.root / "fake-state.json").read_text())
        return value, value, [None] * value["revision"]
def snapshot_data(definition, _projection, _events): return definition
PY

python3 - "$STATE" <<'PY'
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
digest = "sha256:" + "0" * 64
authority = {}
(root / "authority/control-graph-public-key.json").write_text(json.dumps(authority) + "\n")
def binding(binding_id, lane, runner, fill):
    return {"schemaVersion": "operator.actor-binding/v1", "bindingId": binding_id, "generation": 1,
            "projectId": "host-project", "graphId": "host-smoke", "issuedAt": "2020-01-01T00:00:00Z",
            "expiresAt": "2099-01-01T00:00:00Z", "subject": {"type": "host", "id": runner,
            "hostRunnerId": runner}, "capabilities": ["lease", "transition"],
            "leaseScopes": [{"scope": "scope:" + lane, "laneNodeId": lane}],
            "proofKey": {"keyId": "proof-" + binding_id, "algorithm": "RS256",
            "publicKey": {"n": "c" * 256, "e": 65537}}, "bindingHash": "sha256:" + fill * 64,
            "capabilityHash": digest, "authorityHash": digest, "keyId": "authority-key",
            "signature": "A"}
for binding_id, lane, runner, fill in (("host-a", "lane-a", "codex-cli", "a"),
                                       ("host-b", "lane-b", "claude-code", "b")):
    path = root / "graph/bindings" / (binding_id + ".json")
    path.write_text(json.dumps(binding(binding_id, lane, runner, fill), sort_keys=True, separators=(",", ":")) + "\n")
for path in [root / "authority/control-graph-public-key.json", *list((root / "graph/bindings").glob("*.json"))]:
    os.chmod(path, 0o600)
def lane(name):
    return {"id": name, "kind": "lane", "title": name, "initialState": "planned",
            "priority": 0, "metadata": {}, "state": "planned"}
def task(name):
    return {"id": name, "kind": "task", "title": "Hostile task", "initialState": "pending",
            "priority": 10, "metadata": {"execution": {"idempotent": True, "reclaimable": True},
            "scheduler": {"claims": {"files": ["scripts/owned"], "contracts": [],
            "resources": [], "lanes": []}}}, "state": "pending"}
value = {"schemaVersion": "operator.control-snapshot/v1", "graphId": "host-smoke", "revision": 1,
         "definitionRevision": 1, "definitionHash": digest, "updatedAt": "2026-07-22T00:00:00Z",
         "eventCount": 1, "nodes": [lane("lane-a"), task("task-a"), lane("lane-b"), task("task-b")],
         "edges": [{"id": "a", "kind": "assigned-to", "from": "task-a", "to": "lane-a", "metadata": {}},
                   {"id": "b", "kind": "assigned-to", "from": "task-b", "to": "lane-b", "metadata": {}}],
         "leases": {}, "leaseFences": {}, "executionStarted": {}, "reconciliations": {},
         "bindingGenerations": {}, "authorityKeyId": "fake", "authorityHash": digest}
(root / "fake-state.json").write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
os.chmod(root / "fake-state.json", 0o600)
PY

cat > "$RUNTIME/operator-graph.sh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:] != ["snapshot"]: raise SystemExit(64)
value = json.loads((Path(os.environ["OPERATOR_DIR"]) / "fake-state.json").read_text())
print(json.dumps({"ok": True, "command": "snapshot", "data": value}, sort_keys=True, separators=(",", ":")))
PY
chmod 700 "$RUNTIME/operator-graph.sh"

cat > "$RUNTIME/operator-loop.sh" <<'PY'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["OPERATOR_DIR"])
if (root / "kill-loop-parent").exists():
    key = "sha256:" + __import__("hashlib").sha256(b"host-smoke\0task-a").hexdigest()
    request = {"schemaVersion": "operator.runner-request/v1", "tickId": "parent-death",
               "runId": "stale-run", "idempotencyKey": key, "graphId": "host-smoke",
               "node": {"nodeId": "task-a", "kind": "task", "title": "Hostile task",
                        "claims": {"files": ["scripts/owned"], "contracts": [],
                                   "resources": [], "lanes": ["lane-a"]}},
               "lease": {"leaseId": "stale-lease", "fence": 1,
                         "expiresAt": "2099-01-01T00:00:00Z"}}
    stale = subprocess.run([os.environ["OPERATOR_LOOP_RUNNER_COMMAND"]],
                           input=json.dumps(request, separators=(",", ":")).encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    (root / "combined-stale-runner.out").write_bytes(stale.stdout)
    (root / "combined-stale-runner.rc").write_text(str(stale.returncode))
    probe = (root / "hostile-probe-path").read_text().strip()
    codex = (root / "hostile-codex-path").read_text().strip()
    worktree = str(Path(probe).parent)
    sandbox = subprocess.run([codex, "sandbox", "-c", 'sandbox_mode="workspace-write"',
                              "-C", worktree, probe], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, check=False)
    (root / "combined-sandbox.rc").write_text(str(sandbox.returncode))
    (root / "combined-sandbox.err").write_bytes(sandbox.stderr)
    time.sleep(0.05)
    os.kill(os.getpid(), signal.SIGKILL)
snapshot = subprocess.check_output([os.environ["OPERATOR_LOOP_SNAPSHOT_COMMAND"]])
clock = subprocess.check_output([os.environ["OPERATOR_LOOP_CLOCK_COMMAND"]])
assert json.loads(snapshot)["data"]["schemaVersion"] == "operator.control-snapshot/v1"
assert json.loads(clock)["schemaVersion"] == "operator.scheduler-clock/v1"
print(json.dumps({"ok": True, "command": "tick", "data": {"dryRun": True, "interfaces": 2}},
                 sort_keys=True, separators=(",", ":")))
PY
chmod 700 "$RUNTIME/operator-loop.sh"

HOST=("$RUNTIME/operator-host.sh")
cat > "$TMP_ROOT/initial-impostor.py" <<'PY'
import os, subprocess, sys, time
host, tool, session, scope, output, status = sys.argv[1:]
if os.fork():
    os.wait()
    raise SystemExit(0)
os.setsid()
if os.fork():
    raise SystemExit(0)
time.sleep(0.05)
with open(output, "wb") as stream:
    completed = subprocess.run([host, "bind", "--tool", tool, "--session", session,
                                "--scope", scope, "--json"], stdout=stream,
                               stderr=subprocess.STDOUT, check=False)
with open(status, "w", encoding="ascii") as stream:
    stream.write(str(completed.returncode) + "\n")
PY
for impostor in 'codex codex-impostor task-a' 'claude claude-impostor task-b'; do
  read -r impostor_tool impostor_session impostor_scope <<< "$impostor"
  impostor_out="$TMP_ROOT/impostor-$impostor_tool.out"
  impostor_rc="$TMP_ROOT/impostor-$impostor_tool.rc"
  /usr/bin/python3 "$TMP_ROOT/initial-impostor.py" "${HOST[0]}" "$impostor_tool" \
    "$impostor_session" "$impostor_scope" "$impostor_out" "$impostor_rc"
  for _ in $(seq 1 100); do [ -f "$impostor_rc" ] && break; sleep 0.02; done
  test -f "$impostor_rc" && test "$(cat "$impostor_rc")" -ne 0
  grep -q 'AUTHORITY_DENIED' "$impostor_out" || {
    cat "$impostor_out" >&2
    printf 'initial impostor did not fail at the authority boundary\n' >&2
    exit 1
  }
done
/usr/bin/python3 - "$RUNTIME/operator_host.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("claude_preflight", sys.argv[1])
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
for tool, invocation in (
    ("codex", "codex --sandbox workspace-write --sandbox danger-full-access"),
    ("claude", "claude --permission-mode dontAsk --permission-mode acceptEdits"),
):
    try:
        host.validate_lane_invocation(tool, {"lane": "duplicate-option", "invocation": invocation})
    except host.HostError as exc:
        assert exc.code == "TRUSTED_POLICY_UNAVAILABLE"
    else:
        raise AssertionError(f"duplicate {tool} policy option was accepted")
runner = host.resolve_runner_executable("claude")
try:
    host.runner_preflight("claude", runner)
except host.HostError as exc:
    assert exc.code == "RUNNER_UNAVAILABLE" and "credentials" in exc.message
else:
    raise AssertionError("Claude credentials are available; this smoke requires an actual Claude sandbox exercise")
print("actual Claude credential preflight failed closed as expected")
PY

bind_fixture() {
  /usr/bin/python3 - "$RUNTIME/operator_host.py" "$1" "$2" "$3" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("host_fixture", sys.argv[1])
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
host.require_initial_bind_peer = lambda _tool, _runner: None
host.runner_preflight = lambda _tool, _runner: None
root = host.command_root()
host._ACTIVE_HOST_ROOT = root
try:
    record = host.bind_session(sys.argv[2], sys.argv[3], sys.argv[4])
finally:
    host._ACTIVE_HOST_ROOT = None
    root.close()
sys.stdout.buffer.write(host.canonical(host.response("bind", host.scope_payload(record))))
PY
}
bind_fixture codex codex-one task-a > "$TMP_ROOT/codex.json"
bind_fixture claude claude-one task-b > "$TMP_ROOT/claude.json"
"${HOST[@]}" current --tool codex --session codex-one --scope task-a --json > "$TMP_ROOT/current.json"
python3 - "$TMP_ROOT/codex.json" "$TMP_ROOT/claude.json" "$TMP_ROOT/current.json" <<'PY'
import json, sys
codex, claude, current = [json.load(open(path))["data"] for path in sys.argv[1:]]
assert codex == current and codex["scope"] == "task-a" and claude["scope"] == "task-b"
assert codex["actorBindingId"] != claude["actorBindingId"]
PY

if "${HOST[@]}" current --tool codex --session codex-one --scope task-b --json >/dev/null 2>&1; then
  printf 'wrong session scope was accepted\n' >&2
  exit 1
fi
codex_record="$(find "$STATE/host/sessions/codex" -type f -name '*.json')"
claude_record="$(find "$STATE/host/sessions/claude" -type f -name '*.json')"
cp "$codex_record" "$claude_record"
if "${HOST[@]}" current --tool claude --session claude-one --scope task-b --json >/dev/null 2>&1; then
  printf 'copied session binding was accepted\n' >&2
  exit 1
fi
rm "$claude_record"
bind_fixture claude claude-one task-b >/dev/null

"${HOST[@]}" goal-context --tool codex --session codex-one --scope task-a --json > "$TMP_ROOT/goal.json"
grep -q '"activated":false' "$TMP_ROOT/goal.json"

# Reproduce the macOS process topology without depending on the machine's
# launchd policy.  A real wrapper/loop/interface-client/relay process chain runs
# while the parent retains command_root LOCK_EX.  The four-second bound makes
# the historical child command_root re-flock deadlock deterministic.
/usr/bin/python3 -E -s - "$RUNTIME/operator_host.py" <<'PY'
import contextlib
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("fake_launchd_host", sys.argv[1])
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
real_run = host.subprocess.run
job = {}

def completed(command, code=0, error=b""):
    return subprocess.CompletedProcess(command, code, stdout=b"", stderr=error)

def fake_launchctl(command, *args, **kwargs):
    values = list(command)
    if values[:2] == ["/bin/launchctl", "submit"]:
        output_path = values[values.index("-o") + 1]
        error_path = values[values.index("-e") + 1]
        wrapper = values[-1]
        output = open(output_path, "wb")
        error = open(error_path, "wb")
        try:
            process = subprocess.Popen([wrapper], stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=error,
                                       start_new_session=True)
        finally:
            output.close(); error.close()
        job["process"] = process
        return completed(command)
    if values[:2] == ["/bin/launchctl", "print"]:
        return completed(command)
    if values[:2] in (["/bin/launchctl", "kill"], ["/bin/launchctl", "remove"]):
        process = job.get("process")
        if process is not None and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        return completed(command)
    return real_run(command, *args, **kwargs)

root = host.command_root()
host._ACTIVE_HOST_ROOT = root
original_platform = host.sys.platform
host.sys.platform = "darwin"
host.subprocess.run = fake_launchctl
started = time.monotonic()
try:
    record = host.load_session("codex", "codex-one", "task-a")
    try:
        code, output, error = host.supervised_loop(record, 1, True, supervision_timeout=4)
    except host.HostError as exc:
        raise AssertionError((exc.code, exc.message, exc.details)) from exc
    elapsed = time.monotonic() - started
    assert code == 0, (code, output, error)
    value = json.loads(output)
    assert value["data"] == {"dryRun": True, "interfaces": 2}, value
    assert elapsed < 4, elapsed
    assert "process" in job
finally:
    process = job.get("process")
    if process is not None and process.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)
    host.subprocess.run = real_run
    host.sys.platform = original_platform
    host._ACTIVE_HOST_ROOT = None
    root.close()
PY

# Parent lifetime is enforced while a relay request is active, not only while
# the relay is between requests.  Block the clock inside a separate process
# group, kill the command-root owner, and require the relay, its tracked child,
# and the client to fail closed within a short bound.
relay_death_root="$TMP_ROOT/relay-parent-death"
mkdir -m 700 "$relay_death_root"
touch "$STATE/block-relay-clock"
cat > "$TMP_ROOT/relay-parent-death.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

runtime, control = sys.argv[1:]
control_root = Path(control)
spec = importlib.util.spec_from_file_location("relay_parent_death_host", runtime)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
root = host.command_root()
host._ACTIVE_HOST_ROOT = root
record = host.load_session("codex", "codex-one", "task-a")
invocation, _invocation_record = host.create_invocation(record)
relay = host.InterfaceRelay(record, invocation, control_root, 16)
wrapper = control_root / "clock"
host.interface_wrapper(wrapper, "clock", relay)
client = subprocess.Popen([
    "/bin/sh", "-c",
    '"$1" >"$2" 2>"$3"; result=$?; printf "%s\\n" "$result" >"$4"',
    "relay-client", str(wrapper), str(control_root / "client.out"),
    str(control_root / "client.err"), str(control_root / "client.rc")],
    start_new_session=True)
(control_root / "relay.pid").write_text(str(relay.process.pid) + "\n")
(control_root / "client.pid").write_text(str(client.pid) + "\n")
(control_root / "parent-ready").write_text("ready\n")
while True:
    time.sleep(60)
PY
/usr/bin/python3 -E -s "$TMP_ROOT/relay-parent-death.py" \
  "$RUNTIME/operator_host.py" "$relay_death_root" &
relay_parent_pid=$!
for _ in $(seq 1 500); do
  [ -f "$relay_death_root/parent-ready" ] && [ -f "$STATE/blocked-relay-child-ready" ] && break
  sleep 0.01
done
test -f "$relay_death_root/parent-ready"
test -f "$STATE/blocked-relay-child-ready"
relay_pid="$(cat "$relay_death_root/relay.pid")"
relay_client_pid="$(cat "$relay_death_root/client.pid")"
relay_child_pid="$(cat "$STATE/blocked-relay-child.pid")"
kill -0 "$relay_parent_pid" "$relay_pid" "$relay_client_pid" "$relay_child_pid" 2>/dev/null
kill -KILL "$relay_parent_pid"
set +e
wait "$relay_parent_pid" 2>/dev/null
set -e
for _ in $(seq 1 400); do
  relay_alive=0; kill -0 "$relay_pid" 2>/dev/null && relay_alive=1
  client_alive=0; kill -0 "$relay_client_pid" 2>/dev/null && client_alive=1
  child_alive=0; kill -0 "$relay_child_pid" 2>/dev/null && child_alive=1
  if [ "$relay_alive" -eq 0 ] && [ "$client_alive" -eq 0 ] \
      && [ "$child_alive" -eq 0 ] && [ -f "$relay_death_root/client.rc" ]; then
    break
  fi
  sleep 0.01
done
test "$relay_alive" -eq 0
test "$client_alive" -eq 0
test "$child_alive" -eq 0
test -f "$relay_death_root/client.rc"
test "$(cat "$relay_death_root/client.rc")" -ne 0
test ! -s "$relay_death_root/client.out"
grep -q 'HOST_SUPERVISION' "$relay_death_root/client.err"
test ! -e "$STATE/blocked-relay-child-finished"
if find "$relay_death_root/interface-capability" -type f -name 'response-*.frame' -print -quit | grep -q .; then
  printf 'parent-dead interface relay published a response\n' >&2
  exit 1
fi
/usr/bin/python3 -E -s - "$STATE" <<'PY'
import fcntl, os, sys
for path in (sys.argv[1], os.path.join(sys.argv[1], "blocked-relay-child.lock")):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)
PY
rm "$STATE/block-relay-clock"

launchd_available=1
set +e
"${HOST[@]}" tick --tool codex --session codex-one --scope task-a --dry-run --json \
  >"$TMP_ROOT/tick.out" 2>"$TMP_ROOT/tick.err"
tick_rc=$?
set -e
if [ "$tick_rc" -eq 0 ]; then
  grep -q '"interfaces":2' "$TMP_ROOT/tick.out"
else
  grep -q 'HOST_CONTAINMENT_UNAVAILABLE' "$TMP_ROOT/tick.err"
  launchd_available=0
fi

poison_names=(
  OPERATOR_HOST_TEST_MODE OPERATOR_HOST_TEST_SIGNER OPERATOR_HOST_TEST_RUNNER
  OPERATOR_LOOP_TEST_MODE OPERATOR_LOOP_SCHEDULER OPERATOR_LOOP_SNAPSHOT_COMMAND
  OPERATOR_LOOP_MUTATION_COMMAND OPERATOR_DIR CODE_DIR OPERATOR_LANES OPERATOR_CONFIG
  OPERATOR_HOST_SCRIPT_DIR OPERATOR_HOST_RUNNER_COMMAND
)
for poison_name in "${poison_names[@]}"; do
  if env "$poison_name=attacker" "${HOST[@]}" current --tool codex --session codex-one --scope task-a --json \
      >/dev/null 2>&1; then
    printf 'production accepted poisoned variable: %s\n' "$poison_name" >&2
    exit 1
  fi
done

mkdir -p "$TMP_ROOT/malicious-bin"
for poisoned_command in python3 git codex claude; do
cat > "$TMP_ROOT/malicious-bin/$poisoned_command" <<EOF
#!/bin/sh
touch "$TMP_ROOT/path-poison-$poisoned_command-ran"
exit 99
EOF
chmod 700 "$TMP_ROOT/malicious-bin/$poisoned_command"
done
PATH="$TMP_ROOT/malicious-bin:$PATH" "${HOST[@]}" current --tool codex --session codex-one --scope task-a --json >/dev/null
PATH="$TMP_ROOT/malicious-bin:$PATH" bind_fixture codex codex-path task-a >/dev/null
PATH="$TMP_ROOT/malicious-bin:$PATH" bind_fixture claude claude-path task-b >/dev/null
for poisoned_command in python3 git codex claude; do
  test ! -e "$TMP_ROOT/path-poison-$poisoned_command-ran"
done

# Python startup injection is blocked before operator_host.py imports, while
# the fixed launcher PATH also protects the sibling graph module's sysctl/ps
# lookups. An empty PYTHONHOME would make an unisolated interpreter fail before
# the host's Python-level environment rejection could run.
mkdir -p "$TMP_ROOT/startup-malicious-bin" "$TMP_ROOT/python-path-poison" "$TMP_ROOT/python-home-poison"
cat > "$TMP_ROOT/python-path-poison/sitecustomize.py" <<'PY'
import os
with open(os.environ["HOST_PYTHONPATH_POISON_MARKER"], "w", encoding="utf-8") as marker:
    marker.write("poison imported\n")
PY
for poisoned_command in python3 sysctl ps; do
cat > "$TMP_ROOT/startup-malicious-bin/$poisoned_command" <<'SH'
#!/bin/sh
case "${0##*/}" in
  python3) marker_path="${HOST_PATH_POISON_python3_MARKER:?}" ;;
  sysctl) marker_path="${HOST_PATH_POISON_sysctl_MARKER:?}" ;;
  ps) marker_path="${HOST_PATH_POISON_ps_MARKER:?}" ;;
  *) exit 98 ;;
esac
: > "$marker_path"
exit 99
SH
chmod 700 "$TMP_ROOT/startup-malicious-bin/$poisoned_command"
done
/usr/bin/env \
  PATH="$TMP_ROOT/startup-malicious-bin" \
  PYTHONPATH="$TMP_ROOT/python-path-poison" \
  PYTHONHOME="$TMP_ROOT/python-home-poison" \
  HOST_PYTHONPATH_POISON_MARKER="$TMP_ROOT/host-pythonpath-poison-ran" \
  HOST_PATH_POISON_python3_MARKER="$TMP_ROOT/host-path-python3-ran" \
  HOST_PATH_POISON_sysctl_MARKER="$TMP_ROOT/host-path-sysctl-ran" \
  HOST_PATH_POISON_ps_MARKER="$TMP_ROOT/host-path-ps-ran" \
  "${HOST[@]}" current --tool codex --session codex-one --scope task-a --json >/dev/null
for poison_marker in host-pythonpath-poison-ran host-path-python3-ran host-path-sysctl-ran host-path-ps-ran; do
  test ! -e "$TMP_ROOT/$poison_marker" || {
    printf 'trusted host launcher consumed startup/PATH poison: %s\n' "$poison_marker" >&2
    exit 1
  }
done

# The proof broker is a distinct trusted launcher of the same Python helper.
# Its check reaches the real bound session and sibling graph fixture, then
# fails normally because this smoke never provisions a production proof key.
set +e
/usr/bin/env \
  PATH="$TMP_ROOT/startup-malicious-bin" \
  PYTHONPATH="$TMP_ROOT/python-path-poison" \
  PYTHONHOME="$TMP_ROOT/python-home-poison" \
  HOST_PYTHONPATH_POISON_MARKER="$TMP_ROOT/broker-pythonpath-poison-ran" \
  HOST_PATH_POISON_python3_MARKER="$TMP_ROOT/broker-path-python3-ran" \
  HOST_PATH_POISON_sysctl_MARKER="$TMP_ROOT/broker-path-sysctl-ran" \
  HOST_PATH_POISON_ps_MARKER="$TMP_ROOT/broker-path-ps-ran" \
  OPERATOR_HOST_TOOL=codex OPERATOR_HOST_SESSION=codex-one OPERATOR_HOST_SCOPE=task-a \
  "$RUNTIME/operator-proof-broker.sh" --check \
  >"$TMP_ROOT/broker-startup.out" 2>&1
broker_startup_rc=$?
set -e
test "$broker_startup_rc" -ne 0 || {
  printf 'proof broker unexpectedly found a production proof key\n' >&2
  exit 1
}
grep -q 'BROKER_UNAVAILABLE' "$TMP_ROOT/broker-startup.out" || {
  cat "$TMP_ROOT/broker-startup.out" >&2
  printf 'proof broker did not reach its normal fail-closed key boundary\n' >&2
  exit 1
}
for poison_marker in broker-pythonpath-poison-ran broker-path-python3-ran broker-path-sysctl-ran broker-path-ps-ran; do
  test ! -e "$TMP_ROOT/$poison_marker" || {
    printf 'trusted proof-broker launcher consumed startup/PATH poison: %s\n' "$poison_marker" >&2
    exit 1
  }
done

identity_out="$TMP_ROOT/identity.out"
identity_rc="$TMP_ROOT/identity.rc"
cat > "$TMP_ROOT/foreign-session.py" <<'PY'
import os
import subprocess
import sys
import time

identity_out, runtime, identity_rc = sys.argv[1:]

if os.fork():
    os.wait()
    raise SystemExit(0)
os.setsid()
if os.fork():
    raise SystemExit(0)
time.sleep(0.05)
with open(identity_out, "wb") as output:
    completed = subprocess.run([
        "python3", runtime + "/operator_host.py", "current", "--tool", "codex",
        "--session", "codex-one", "--scope", "task-a", "--json"
    ], stdout=output, stderr=subprocess.STDOUT, check=False)
with open(identity_rc, "w", encoding="ascii") as result:
    result.write(str(completed.returncode) + "\n")
PY
python3 "$TMP_ROOT/foreign-session.py" "$identity_out" "$RUNTIME" "$identity_rc"
for _ in $(seq 1 100); do [ -f "$identity_rc" ] && break; sleep 0.02; done
test -f "$identity_rc" && test "$(cat "$identity_rc")" -ne 0
grep -q 'AUTHORITY_DENIED' "$identity_out"

python3 "$TEST_SOURCE_ROOT/tests/smoke/v5-host-security.py" \
  --host "$RUNTIME/operator_host.py" --graph "$KIT_ROOT/scripts/operator_graph.py" \
  --record "$codex_record" --binding "$STATE/graph/bindings/host-a.json"

cat > "$TMP_ROOT/network-listener.py" <<'PY'
import pathlib, socket, sys
root = pathlib.Path(sys.argv[1])
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    (root / "network.unavailable").write_text("outer sandbox denied listener")
    raise SystemExit(0)
s.listen(1)
(root / "network.port").write_text(str(s.getsockname()[1]))
s.settimeout(10)
try:
    connection, _ = s.accept()
except TimeoutError:
    pass
else:
    (root / "network-escaped").write_text("connected")
    connection.close()
PY
python3 "$TMP_ROOT/network-listener.py" "$TMP_ROOT" &
network_server_pid=$!
for _ in $(seq 1 100); do
  [ -f "$TMP_ROOT/network.port" ] || [ -f "$TMP_ROOT/network.unavailable" ] && break
  sleep 0.02
done
if [ -f "$TMP_ROOT/network.port" ]; then
  network_port="$(cat "$TMP_ROOT/network.port")"
else
  test -f "$TMP_ROOT/network.unavailable"
  network_port=9
fi

probe="$CODE/lane-a/native-sandbox-double-fork.sh"
cat > "$probe" <<EOF
#!/bin/sh
set +e
export SURVIVOR_SCRIPT="$CODE/lane-a/native-sandbox-survivor.sh"
(
  /usr/bin/python3 - <<'PY'
import os
if os.fork():
    raise SystemExit(0)
os.setsid()
if os.fork():
    raise SystemExit(0)
os.execl(os.environ["SURVIVOR_SCRIPT"], "native-sandbox-survivor.sh")
PY
)
exit 0
EOF
cat > "$CODE/lane-a/native-sandbox-survivor.sh" <<EOF
#!/bin/sh
set +e
printf '%s\n' "\$\$" > "$CODE/lane-a/sandbox-survivor.pid"
ps -p "\$\$" -o lstart= > "$CODE/lane-a/sandbox-survivor.start"
test -s "$CODE/lane-a/sandbox-survivor.start" || exit 90
printf poison > "$STATE/graph/poison" 2>/dev/null && touch "$CODE/lane-a/graph-escaped"
printf poison > "$STATE/graph/bindings/host-a.json" 2>/dev/null && touch "$CODE/lane-a/binding-escaped"
/usr/bin/security find-generic-password -s agent-operator-kit.proof-key -a proof-host-a -w >/dev/null 2>&1 && touch "$CODE/lane-a/keychain-escaped"
/usr/bin/nc -G 1 127.0.0.1 "$network_port" </dev/null >/dev/null 2>&1 && touch "$CODE/lane-a/network-command-succeeded"
printf poison > "$CODE/lane-b/escaped" 2>/dev/null && touch "$CODE/lane-a/other-root-escaped"
mkdir -p "$STATE/host/handoffs/lane-a/task-a/runs/stale/999" 2>/dev/null
printf poison > "$STATE/host/handoffs/lane-a/task-a/runs/stale/999/accepted.json" 2>/dev/null && touch "$CODE/lane-a/stale-effect-escaped"
touch "$CODE/lane-a/sandbox-attempts-complete"
counter=0
while :; do
  counter=\$((counter + 1))
  printf '%s\n' "\$counter" > "$CODE/lane-a/sandbox-survivor.heartbeat"
  sleep 0.02
done
EOF
chmod 700 "$probe" "$CODE/lane-a/native-sandbox-survivor.sh"
if [ "$launchd_available" -eq 1 ]; then
  printf '%s\n' "$probe" > "$STATE/hostile-probe-path"
  command -v codex > "$STATE/hostile-codex-path"
  touch "$STATE/kill-loop-parent"
  set +e
  "${HOST[@]}" tick --tool codex --session codex-one --scope task-a --json \
    >"$TMP_ROOT/death.out" 2>"$TMP_ROOT/death.json"
  death_rc=$?
  set -e
  test "$death_rc" -ne 0
  grep -q 'HOST_SUPERVISION' "$TMP_ROOT/death.json"
  grep -q 'inherited-native-runner-sandbox' "$TMP_ROOT/death.json"
  test "$(cat "$STATE/combined-stale-runner.rc")" -ne 0
  grep -q 'FENCE_STALE' "$STATE/combined-stale-runner.out"
  probe_rc="$(cat "$STATE/combined-sandbox.rc")"
  cp "$STATE/combined-sandbox.err" "$TMP_ROOT/sandbox-probe.err"
  rm "$STATE/kill-loop-parent"
else
  set +e
  codex sandbox -c 'sandbox_mode="workspace-write"' -C "$CODE/lane-a" "$probe" \
    >"$TMP_ROOT/sandbox-probe.out" 2>"$TMP_ROOT/sandbox-probe.err"
  probe_rc=$?
  set -e
fi
if [ "$probe_rc" -eq 0 ]; then
  for _ in $(seq 1 100); do [ -f "$CODE/lane-a/sandbox-attempts-complete" ] && break; sleep 0.02; done
  test -f "$CODE/lane-a/sandbox-attempts-complete"
  sandbox_survivor_pid="$(cat "$CODE/lane-a/sandbox-survivor.pid")"
  sandbox_survivor_start="$(cat "$CODE/lane-a/sandbox-survivor.start")"
  heartbeat_one="$(cat "$CODE/lane-a/sandbox-survivor.heartbeat")"
  sleep 0.1
  heartbeat_two="$(cat "$CODE/lane-a/sandbox-survivor.heartbeat")"
  test "$heartbeat_one" != "$heartbeat_two"
  test ! -e "$CODE/lane-a/graph-escaped"
  test ! -e "$CODE/lane-a/binding-escaped"
  test ! -e "$CODE/lane-a/keychain-escaped"
  test ! -e "$CODE/lane-a/network-command-succeeded"
  test ! -e "$CODE/lane-a/other-root-escaped"
  test ! -e "$CODE/lane-a/stale-effect-escaped"
  test ! -e "$TMP_ROOT/network-escaped"
  current_start="$(ps -p "$sandbox_survivor_pid" -o lstart= 2>/dev/null || true)"
  test "$current_start" = "$sandbox_survivor_start"
  kill -KILL "$sandbox_survivor_pid"
  for _ in $(seq 1 100); do
    current_start="$(ps -p "$sandbox_survivor_pid" -o lstart= 2>/dev/null || true)"
    [ "$current_start" != "$sandbox_survivor_start" ] && break
    sleep 0.01
  done
  test "$current_start" != "$sandbox_survivor_start"
  sandbox_survivor_pid=""
  sandbox_survivor_start=""
else
  grep -Eq 'sandbox_apply|denied|not permitted|permission' "$TMP_ROOT/sandbox-probe.err"
  test ! -e "$CODE/lane-a/sandbox-survivor.pid"
fi
kill "$network_server_pid" 2>/dev/null || true
wait "$network_server_pid" 2>/dev/null || true
network_server_pid=""

codex_bypass='dangerously-bypass-approvals-and-'"sandbox"
claude_bypass='dangerously-skip-'"permissions"
claude_mode='bypass'"Permissions"
if rg -n --glob '!tasks/contract-fix.md' "$codex_bypass|$claude_bypass|$claude_mode" "$KIT_ROOT"; then
  printf 'repository still contains a shipped permission bypass\n' >&2
  exit 1
fi

if [ "$launchd_available" -eq 1 ]; then
  printf 'v5 host runners smoke ok: launchd and hostile containment exercised\n'
else
  printf 'v5 host runners smoke partial: launchd unavailable and failed closed; hostile matrix exercised\n'
fi
