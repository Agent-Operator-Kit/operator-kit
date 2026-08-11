#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-provision.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PYTHONPATH="$KIT_ROOT/scripts" /usr/bin/python3 - "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
project = root / "project"
code = project / "code"
operator = project / "operator"
repo = code / "app"
worker = code / "app-worker"
for path in (operator / "catalog", repo, worker):
    path.mkdir(parents=True, exist_ok=True)

config = repo / "operator.config.env"
config.write_text(
    f'''PROJECT_NAME="provision-smoke"
PROJECT_ROOT="{project}"
CODE_DIR="{code}"
OPERATOR_DIR="{operator}"
TMUX_SESSION="provision-smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5"
OPERATOR_LANES='\noperator|Codex Desktop|app|main|codex --sandbox workspace-write --ignore-user-config --ignore-rules --ephemeral\nworker|Claude Code|app-worker|claude/worker|claude --permission-mode dontAsk --safe-mode strict --no-session-persistence\n'
''',
    encoding="utf-8",
)
os.chmod(config, 0o600)

role_map = {
    "kind": "operator-role-map", "schemaVersion": 1,
    "roleTemplates": [], "featureInstances": [],
    "hostRunners": [
        {"kind": "host-runner", "id": "codex-desktop", "tool": "Codex Desktop"},
        {"kind": "host-runner", "id": "claude-code", "tool": "Claude Code"},
    ],
    "durableLanes": [
        {"kind": "durable-lane", "id": "operator", "tool": "Codex Desktop",
         "hostRunnerId": "codex-desktop", "worktree": "app", "branch": "main",
         "roleTemplateIds": [], "authority": {"manageQueue": True, "integrate": True}},
        {"kind": "durable-lane", "id": "worker", "tool": "Claude Code",
         "hostRunnerId": "claude-code", "worktree": "app-worker", "branch": "claude/worker",
         "roleTemplateIds": [], "authority": {"manageQueue": False, "integrate": False}},
    ],
}
(operator / "catalog" / "role-map.json").write_text(json.dumps(role_map, indent=2) + "\n", encoding="utf-8")

import operator_v5_provision as provision


class MemoryKeychain:
    def __init__(self):
        self.items = {}

    def get(self, service, account):
        return self.items.get((service, account))

    def put_if_absent(self, service, account, secret):
        key = (service, account)
        if key in self.items:
            if self.items[key] != secret:
                raise AssertionError("test keychain overwrite")
            return False
        self.items[key] = secret
        return True


keychain = MemoryKeychain()

planned = provision.plan(config, None)
assert planned["graphState"] == "absent"
assert planned["hostPolicyReady"] is True, planned
assert not (operator / "graph" / "bindings").exists(), "plan mutated the workspace"

safe_config = config.read_text(encoding="utf-8")
config.write_text(
    safe_config.replace("--sandbox workspace-write", "--sandbox workspace-write --sandbox danger-full-access"),
    encoding="utf-8",
)
duplicated = provision.plan(config, None)
assert duplicated["hostPolicyReady"] is False, duplicated
config.write_text(safe_config, encoding="utf-8")

try:
    provision.apply(config, None, 30, "wrong-token", keychain)
    raise AssertionError("wrong authorization was accepted")
except provision.ProvisionError:
    pass

first = provision.apply(config, None, 30, provision.AUTHORIZATION, keychain)
assert first["ok"] is True and first["eventCount"] == 1 and first["revision"] == 1, first
assert first["alreadyInitialized"] is False
assert set(first["bindingIds"]) == {"control", "human", "host-operator-06e55b63", "host-worker-87eba76e"}

second = provision.apply(config, None, 30, provision.AUTHORIZATION, keychain)
assert second["ok"] is True and second["alreadyInitialized"] is True, second
assert second["createdKeychainEntries"] == []
assert second["createdPublicFiles"] == []

workspace_bytes = b"".join(
    path.read_bytes() for path in operator.rglob("*") if path.is_file()
)
assert provision.AUTHORITY_SECRET_VERSION.encode() not in workspace_bytes
assert provision.PROOF_SECRET_VERSION.encode() not in workspace_bytes
assert b'"d"' not in workspace_bytes

print("operator-v5-provision smoke: ok")
PY
