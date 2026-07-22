#!/usr/bin/env python3
"""Hostile in-process coverage for the RM-0005 trusted host boundary."""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from typing import Any, Mapping


def load_host(path: Path) -> Any:
    spec = importlib.util.spec_from_file_location("operator_host_security_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_error(host: Any, code: str, function: Any) -> None:
    try:
        function()
    except host.HostError as exc:
        assert exc.code == code, (exc.code, exc.message)
    else:
        raise AssertionError(f"expected {code}")


class FakeGraph:
    HOST_ID = "host-smoke-host"
    BOOT_ID = "host-smoke-boot"

    def __init__(self, host: Any):
        self.host = host

    @staticmethod
    def parse_time(value: str, _code: str = "AUTHORITY_DENIED") -> dt.datetime:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))

    @staticmethod
    def utc_now() -> dt.datetime:
        return dt.datetime.now(dt.timezone.utc)

    @staticmethod
    def host_monotonic_sample() -> tuple[str, int]:
        return "macos-mach-continuous", time.monotonic_ns()

    @staticmethod
    def validate_authority(value: Mapping[str, Any]) -> Mapping[str, Any]:
        return value

    @staticmethod
    def validate_binding(value: Mapping[str, Any], binding_id: str,
                         _authority: Mapping[str, Any]) -> Mapping[str, Any]:
        assert value["bindingId"] == binding_id
        return value

    @staticmethod
    def sha256_value(value: Any) -> str:
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(encoded).hexdigest()

    def validate_authorization_payload(self, value: Any, _code: str) -> None:
        fields = {"schemaVersion", "command", "requestId", "bindingId", "bindingGeneration",
                  "bindingHash", "intent", "expectedRevision"}
        assert isinstance(value, dict) and set(value) == fields
        assert value["schemaVersion"] == "operator.mutation-proof-request/v1"
        assert self.host.valid_id(value["requestId"], 256)
        assert self.host.BINDING_RE.fullmatch(value["bindingId"])
        assert self.host.integer(value["bindingGeneration"], 1)
        assert self.host.HASH_RE.fullmatch(value["bindingHash"])
        assert self.host.integer(value["expectedRevision"], 1)
        expected = {
            "lease acquire": {"nodeId", "leaseId", "holderScope", "ttlSeconds"},
            "lease renew": {"nodeId", "leaseId", "fence", "ttlSeconds"},
            "lease release": {"nodeId", "leaseId", "fence"},
            "transition": {"nodeId", "targetState", "leaseId", "fence"},
        }
        command = value["command"]
        assert command in expected and isinstance(value["intent"], dict)
        assert set(value["intent"]) == expected[command]
        intent = value["intent"]
        assert self.host.valid_id(intent["nodeId"], 128)
        assert self.host.valid_id(intent["leaseId"], 256)
        if "fence" in intent:
            assert self.host.integer(intent["fence"], 1)
        if "ttlSeconds" in intent:
            assert self.host.integer(intent["ttlSeconds"], 1) and intent["ttlSeconds"] <= 86400
        if "holderScope" in intent:
            assert self.host.valid_id(intent["holderScope"], 512)
        if "targetState" in intent:
            assert intent["targetState"] in {"active", "completed", "failed"}

    @staticmethod
    def actor_record(binding: Mapping[str, Any]) -> Mapping[str, Any]:
        return {
            "type": binding["subject"]["type"], "id": binding["subject"]["id"],
            "bindingId": binding["bindingId"], "bindingGeneration": binding["generation"],
            "bindingHash": binding["bindingHash"], "capabilityHash": binding["capabilityHash"],
            "projectId": binding["projectId"], "graphId": binding["graphId"],
            "issuedAt": binding["issuedAt"], "expiresAt": binding["expiresAt"],
            "keyId": binding["keyId"], "signature": binding["signature"],
            "capabilities": binding["capabilities"], "subject": binding["subject"],
            "leaseScopes": binding["leaseScopes"], "proofKey": binding["proofKey"],
            "authorityHash": binding["authorityHash"],
        }

    def validate_actor_record(self, actor: Any, _code: str) -> None:
        required = {"type", "id", "bindingId", "bindingGeneration", "bindingHash", "capabilityHash",
                    "projectId", "graphId", "issuedAt", "expiresAt", "keyId", "signature",
                    "capabilities", "subject", "leaseScopes", "proofKey", "authorityHash"}
        assert isinstance(actor, dict) and set(actor) == required

    @staticmethod
    def validate_lease(lease: Any, _code: str) -> None:
        fields = {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt",
                  "expiresAt", "fence", "clock"}
        assert isinstance(lease, dict) and set(lease) == fields


def broker_tests(host: Any, record: Mapping[str, Any], binding: Mapping[str, Any]) -> None:
    graph = FakeGraph(host)
    original_graph = host.graph_module
    host.graph_module = lambda: graph

    authorization = {
        "schemaVersion": "operator.mutation-proof-request/v1", "command": "lease release",
        "requestId": "request-1", "bindingId": record["actorBindingId"],
        "bindingGeneration": record["actorBindingGeneration"],
        "bindingHash": record["actorBindingHash"],
        "intent": {"nodeId": record["nodeId"], "leaseId": "lease-1", "fence": 1},
        "expectedRevision": 1,
    }

    def challenge(phase: str, payload: Mapping[str, Any], key: str | None = None) -> Mapping[str, Any]:
        return {"schemaVersion": host.PROOF_CHALLENGE_VERSION, "operation": "sign", "phase": phase,
                "proofKeyId": key or record["proofKeyId"], "payload": payload}

    def unsigned(auth: Mapping[str, Any] = authorization) -> Mapping[str, Any]:
        source, monotonic_ns = graph.host_monotonic_sample()
        data = dict(auth["intent"])
        return {
            "schemaVersion": "operator.control-event/v1", "sequence": auth["expectedRevision"] + 1,
            "eventId": "event-1", "requestId": auth["requestId"],
            "requestFingerprint": graph.sha256_value(auth), "occurredAt": "2026-07-22T00:00:00Z",
            "clock": {"hostId": graph.HOST_ID, "bootId": graph.BOOT_ID,
                      "monotonicSource": source, "monotonicNs": monotonic_ns},
            "actor": graph.actor_record(binding), "type": "lease.released", "intent": auth["intent"],
            "expectedRevision": auth["expectedRevision"], "data": data,
            "result": {"ok": True, "command": auth["command"], "requestId": auth["requestId"],
                       "revision": auth["expectedRevision"] + 1, "data": data},
        }

    authorize = challenge("authorize", authorization)
    event = challenge("event", {"schemaVersion": "operator.mutation-event-proof/v1", "event": unsigned()})

    def run(records: list[Mapping[str, Any]], signer: Any = None,
            combined: bool = False) -> tuple[list[Mapping[str, Any]], list[BaseException]]:
        parent, child = socket.socketpair()
        errors: list[BaseException] = []
        responses: list[Mapping[str, Any]] = []
        signer = signer or (lambda _payload, _binding: "A" * 43)

        def server() -> None:
            try:
                host.serve_broker(child, record, binding, signer)
            except BaseException as exc:  # test captures fail-closed errors
                errors.append(exc)

        thread = threading.Thread(target=server)
        thread.start()
        try:
            if combined:
                parent.sendall(b"".join(host.canonical(item) for item in records))
                parent.shutdown(socket.SHUT_WR)
            else:
                stream = parent.makefile("rb")
                for index, item in enumerate(records):
                    parent.sendall(host.canonical(item))
                    if index == len(records) - 1:
                        with contextlib.suppress(OSError):
                            parent.shutdown(socket.SHUT_WR)
                    line = stream.readline()
                    if line:
                        responses.append(host.loads(line, "broker response"))
                while stream.readline():
                    pass
        finally:
            parent.close()
            thread.join(timeout=5)
        assert not thread.is_alive()
        return responses, errors

    responses, errors = run([authorize, event])
    assert not errors and [item["phase"] for item in responses] == ["authorize", "event"]

    def lease_event(command: str) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
        acquire = command == "lease acquire"
        auth = copy.deepcopy(authorization)
        auth["command"] = command
        auth["requestId"] = "request-acquire" if acquire else "request-renew"
        auth["expectedRevision"] = 2 if acquire else 3
        auth["intent"] = ({"nodeId": record["nodeId"], "leaseId": "lease-bound",
                           "holderScope": record["holderScope"], "ttlSeconds": 60} if acquire else
                          {"nodeId": record["nodeId"], "leaseId": "lease-bound", "fence": 7,
                           "ttlSeconds": 60})
        source, monotonic_ns = graph.host_monotonic_sample()
        holder = {"actorType": record["actorType"], "actorId": record["actorId"],
                  "bindingId": record["actorBindingId"],
                  "bindingGeneration": record["actorBindingGeneration"],
                  "bindingHash": record["actorBindingHash"], "scope": record["holderScope"],
                  "laneNodeId": record["laneNodeId"]}
        lease = {"schemaVersion": "operator.ownership-lease/v1", "nodeId": record["nodeId"],
                 "leaseId": "lease-bound", "holder": holder,
                 "acquiredAt": "2026-07-22T00:00:00Z" if acquire else "2026-07-21T00:00:00Z",
                 "renewedAt": "2026-07-22T00:00:00Z", "expiresAt": "2026-07-22T00:01:00Z",
                 "fence": 7,
                 "clock": {"hostId": graph.HOST_ID, "bootId": graph.BOOT_ID,
                           "monotonicSource": source,
                           "acquiredMonotonicNs": monotonic_ns if acquire else monotonic_ns - 1_000,
                           "expiresMonotonicNs": monotonic_ns + 60_000_000_000}}
        event_value = {"schemaVersion": "operator.control-event/v1",
                       "sequence": auth["expectedRevision"] + 1, "eventId": "event-acquire" if acquire else "event-renew",
                       "requestId": auth["requestId"], "requestFingerprint": graph.sha256_value(auth),
                       "occurredAt": "2026-07-22T00:00:00Z",
                       "clock": {"hostId": graph.HOST_ID, "bootId": graph.BOOT_ID,
                                 "monotonicSource": source, "monotonicNs": monotonic_ns},
                       "actor": graph.actor_record(binding),
                       "type": "lease.acquired" if acquire else "lease.renewed", "intent": auth["intent"],
                       "expectedRevision": auth["expectedRevision"], "data": {"lease": lease},
                       "result": {"ok": True, "command": command, "requestId": auth["requestId"],
                                  "revision": auth["expectedRevision"] + 1,
                                  "data": {"lease": lease, "reclaimed": False} if acquire else {"lease": lease}}}
        return challenge("authorize", auth), challenge("event", {
            "schemaVersion": "operator.mutation-event-proof/v1", "event": event_value})

    acquire_authorize, acquire_event = lease_event("lease acquire")
    responses, errors = run([acquire_authorize, acquire_event])
    assert not errors and [item["phase"] for item in responses] == ["authorize", "event"]
    renew_authorize, renew_event = lease_event("lease renew")
    responses, errors = run([renew_authorize, renew_event])
    assert not errors and [item["phase"] for item in responses] == ["authorize", "event"]
    holder_poison = {"actorType": "lane", "actorId": "other-actor", "bindingId": "host-b",
                     "bindingGeneration": 99, "bindingHash": "sha256:" + "0" * 64,
                     "scope": "scope:other", "laneNodeId": "lane-b"}
    for field, value in holder_poison.items():
        poisoned = copy.deepcopy(renew_event)
        poisoned["payload"]["event"]["data"]["lease"]["holder"][field] = value
        poisoned["payload"]["event"]["result"]["data"] = poisoned["payload"]["event"]["data"]
        _responses, rejected = run([renew_authorize, poisoned])
        assert rejected and len(_responses) == 1
    for path, value in ((["fence"], 8), (["expiresAt"], "2026-07-22T00:02:00Z"),
                        (["clock", "hostId"], "wrong-host"),
                        (["clock", "expiresMonotonicNs"], 1)):
        poisoned = copy.deepcopy(renew_event)
        target = poisoned["payload"]["event"]["data"]["lease"]
        if len(path) == 1:
            target[path[0]] = value
        else:
            target[path[0]][path[1]] = value
        poisoned["payload"]["event"]["result"]["data"] = poisoned["payload"]["event"]["data"]
        _responses, rejected = run([renew_authorize, poisoned])
        assert rejected and len(_responses) == 1

    replay_parent, replay_child = socket.socketpair()
    replay_errors: list[BaseException] = []
    thread = threading.Thread(target=lambda: _capture_broker(host, replay_child, record, binding, replay_errors))
    thread.start()
    replay_stream = replay_parent.makefile("rb")
    replay_parent.sendall(host.canonical(authorize))
    assert host.loads(replay_stream.readline(), "authorize response")["phase"] == "authorize"
    replay_parent.sendall(host.canonical(event))
    time.sleep(0.05)
    with contextlib.suppress(BrokenPipeError, ConnectionResetError, OSError):
        replay_parent.sendall(host.canonical(event))
        replay_parent.shutdown(socket.SHUT_WR)
    assert replay_stream.readline() == b""
    replay_parent.close()
    thread.join(timeout=5)
    assert replay_errors and isinstance(replay_errors[0], host.HostError)

    hostile_first = []
    wrong_binding = copy.deepcopy(authorize)
    wrong_binding["payload"]["bindingId"] = "host-b"
    hostile_first.append(wrong_binding)
    hostile_first.append(challenge("authorize", authorization, "wrong-key"))
    hostile_first.append(event)
    extra = copy.deepcopy(authorize)
    extra["payload"]["extra"] = True
    hostile_first.append(extra)
    bad_request = copy.deepcopy(authorize)
    bad_request["payload"]["requestId"] = "bad request"
    hostile_first.append(bad_request)
    bad_ttl_auth = copy.deepcopy(authorization)
    bad_ttl_auth["command"] = "lease acquire"
    bad_ttl_auth["intent"] = {"nodeId": record["nodeId"], "leaseId": "lease-2",
                              "holderScope": record["holderScope"], "ttlSeconds": 86401}
    hostile_first.append(challenge("authorize", bad_ttl_auth))
    for item in hostile_first:
        _responses, rejected = run([item], combined=True)
        assert rejected

    event_mutations = []
    for field, value in (("requestFingerprint", "sha256:" + "0" * 64), ("sequence", 9),
                         ("type", "lease.renewed")):
        changed = copy.deepcopy(event)
        changed["payload"]["event"][field] = value
        event_mutations.append(changed)
    changed = copy.deepcopy(event)
    changed["payload"]["event"]["extra"] = True
    event_mutations.append(changed)
    changed = copy.deepcopy(event)
    changed["payload"]["event"]["clock"]["bootId"] = "wrong-boot"
    event_mutations.append(changed)
    changed = copy.deepcopy(event)
    changed["payload"]["event"]["actor"]["bindingHash"] = "sha256:" + "0" * 64
    event_mutations.append(changed)
    changed = copy.deepcopy(event)
    changed["payload"]["event"]["result"]["revision"] = 99
    event_mutations.append(changed)
    for item in event_mutations:
        _responses, rejected = run([authorize, item])
        assert rejected and len(_responses) == 1

    _responses, rejected = run([authorize, event], combined=True)
    assert rejected
    unavailable = lambda _payload, _binding: (_ for _ in ()).throw(
        host.HostError("BROKER_UNAVAILABLE", "test signer unavailable", exit_code=3))
    _responses, rejected = run([authorize], signer=unavailable, combined=True)
    assert rejected and isinstance(rejected[0], host.HostError)

    missing_key = copy.deepcopy(binding)
    missing_key["proofKey"]["keyId"] = "proof-host-smoke-key-that-does-not-exist"
    expect_error(host, "BROKER_UNAVAILABLE", lambda: host.private_key_secret(missing_key))

    original_script_dir = host.script_dir
    with tempfile.TemporaryDirectory() as missing:
        host.script_dir = lambda: Path(missing)
        expect_error(host, "BROKER_UNAVAILABLE", lambda: host._execute_mutation(record, authorization))
    host.script_dir = original_script_dir
    host.graph_module = original_graph


def _capture_broker(host: Any, channel: socket.socket, record: Mapping[str, Any],
                    binding: Mapping[str, Any], errors: list[BaseException]) -> None:
    try:
        host.serve_broker(channel, record, binding, lambda _payload, _binding: "A" * 43)
    except BaseException as exc:
        errors.append(exc)


def path_tests(host: Any) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        root = base / "root"
        outside = base / "outside"
        root.mkdir(mode=0o700)
        outside.mkdir(mode=0o700)
        with host.AnchoredStore(root) as store:
            store.atomic_write_bytes(("private", "value"), b"safe", private=True)
            assert (root / "private").stat().st_mode & 0o777 == 0o700
            assert (root / "private" / "value").stat().st_mode & 0o777 == 0o600

            (root / "parent-link").symlink_to(outside, target_is_directory=True)
            try:
                store.atomic_write_bytes(("parent-link", "escaped"), b"bad", private=True)
            except (OSError, host.HostError):
                pass
            else:
                raise AssertionError("symlink parent was followed")
            assert not (outside / "escaped").exists()

            (root / "private" / "leaf-link").symlink_to(outside / "leaf")
            expect_error(host, "IO_ERROR", lambda: store.atomic_write_bytes(("private", "leaf-link"), b"bad"))
            assert not (outside / "leaf").exists()

            hard_source = root / "private" / "hard-source"
            hard_source.write_bytes(b"hard")
            os.chmod(hard_source, 0o600)
            os.link(hard_source, root / "private" / "hard-link")
            expect_error(host, "IO_ERROR", lambda: store.read_bytes(("private", "hard-link"), 64))

            safe_dir = root / "swap"
            safe_dir.mkdir(mode=0o700)
            safe_dir.rename(root / "swap-old")
            (root / "swap").symlink_to(outside, target_is_directory=True)
            try:
                store.atomic_write_bytes(("swap", "escaped"), b"bad")
            except (OSError, host.HostError):
                pass
            else:
                raise AssertionError("renamed directory symlink was followed")
            assert not (outside / "escaped").exists()

            old_root = base / "old-root"
            root.rename(old_root)
            root.mkdir(mode=0o700)
            expect_error(host, "IO_ERROR", lambda: store.atomic_write_bytes(
                ("anchored-after-root-swap",), b"old inode"))
            assert not (old_root / "anchored-after-root-swap").exists()
            assert not (root / "anchored-after-root-swap").exists()


def lease_snapshot(host: Any, record: Mapping[str, Any], fence: int = 1,
                   lease_id: str = "lease-1", expired: bool = False) -> Mapping[str, Any]:
    now = time.monotonic_ns()
    expires = now - 1 if expired else now + 60_000_000_000
    return {
        "schemaVersion": "operator.control-snapshot/v1", "graphId": record["graphId"], "revision": fence,
        "nodes": [{"id": record["nodeId"], "kind": "task", "title": "Hostile task",
                   "metadata": {"scheduler": {"claims": {"files": ["scripts/owned"],
                   "contracts": [], "resources": [], "lanes": []}}}}],
        "edges": [{"kind": "assigned-to", "from": record["nodeId"], "to": record["laneNodeId"]}],
        "leases": {record["nodeId"]: {
            "leaseId": lease_id, "fence": fence, "expiresAt": "2099-01-01T00:00:00Z",
            "holder": {"bindingId": record["actorBindingId"],
                       "actorType": record["actorType"], "actorId": record["actorId"],
                       "bindingGeneration": record["actorBindingGeneration"],
                       "bindingHash": record["actorBindingHash"], "scope": record["holderScope"],
                       "laneNodeId": record["laneNodeId"]},
            "clock": {"hostId": FakeGraph.HOST_ID, "bootId": FakeGraph.BOOT_ID,
                      "monotonicSource": "macos-mach-continuous", "acquiredMonotonicNs": now - 1_000,
                      "expiresMonotonicNs": expires}}},
        "leaseFences": {record["nodeId"]: fence},
    }


def binding_manifest_stress_tests(host: Any, graph_path: Path,
                                  template: Mapping[str, Any]) -> None:
    original_graph = host.graph_module
    original_lanes = host.parse_lanes
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        (root / "authority").mkdir(mode=0o700)
        (root / "graph" / "bindings").mkdir(parents=True, mode=0o700)
        (root / "authority" / "control-graph-public-key.json").write_bytes(b"{}\n")
        os.chmod(root / "authority" / "control-graph-public-key.json", 0o600)
        selected_id = "stress-selected"
        for index in range(96):
            value = copy.deepcopy(template)
            binding_id = selected_id if index == 47 else f"stress-{index:04d}"
            value["bindingId"] = binding_id
            value["padding"] = "x" * 48000
            if binding_id == selected_id:
                value["subject"] = {"type": "host", "id": "codex-stress",
                                    "hostRunnerId": "codex-cli"}
                value["capabilities"] = sorted(set([*value.get("capabilities", []), "lease"]))
                value["leaseScopes"] = [{"scope": "scope:stress-lane",
                                         "laneNodeId": "stress-lane"}]
            else:
                value["subject"] = {"type": "operator", "id": f"other-{index}"}
                value["capabilities"] = []
                value["leaseScopes"] = []
            path = root / "graph" / "bindings" / f"{binding_id}.json"
            path.write_bytes(host.canonical(value)); os.chmod(path, 0o600)
        graph = FakeGraph(host)
        host.graph_module = lambda: graph
        host.parse_lanes = lambda: {"stress-lane": {
            "lane": "stress-lane", "owner": "Codex CLI", "worktreeName": "stress",
            "branch": "stress", "worktree": str(root),
            "invocation": "codex --sandbox workspace-write",
        }}
        store = host.AnchoredStore(root, acquire_exclusive=True, initialize_capability=True)
        previous = host._ACTIVE_HOST_ROOT
        host._ACTIVE_HOST_ROOT = store
        try:
            snapshot = {"nodes": [{"id": "stress-task"}], "edges": [{
                "kind": "assigned-to", "from": "stress-task", "to": "stress-lane"}]}
            probe = host.validated_actor(selected_id, retain=False)
            assert probe["subject"]["hostRunnerId"] == "codex-cli" and "lease" in probe["capabilities"]
            binding, scope, lane_node, _lane = host.find_binding("codex", "stress-task", snapshot)
            assert binding["bindingId"] == selected_id and scope == "scope:stress-lane"
            assert lane_node == "stress-lane"
            pinned_bindings = [key for key in store.file_fds if key[:2] == ("graph", "bindings")]
            assert pinned_bindings == [("graph", "bindings", f"{selected_id}.json")], pinned_bindings
            environment, descriptors = host.capability_environment("OPERATOR_HOST_ROOT", store)
            leaf_caps = json.loads(environment["OPERATOR_HOST_ROOT_LEAF_CAPS"])
            assert len(leaf_caps) < 16 and len(descriptors) < 20
            manifest_fd = int(environment["OPERATOR_HOST_ROOT_BINDING_MANIFEST_FD"])
            os.lseek(manifest_fd, 0, os.SEEK_SET)
            manifest = json.loads(os.read(manifest_fd, host.MAX_JSON_BYTES))
            assert len(manifest["entries"]) == 96
            assert len(json.dumps(leaf_caps, separators=(",", ":"))) < 4096
            info = os.fstat(store.root_fd)
            child_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                                 "OPERATOR_DIR": str(root), "OPERATOR_HOST_ROOT_FD": str(store.root_fd),
                                 "OPERATOR_HOST_ROOT_DEV": str(info.st_dev), "OPERATOR_HOST_ROOT_INO": str(info.st_ino),
                                 "OPERATOR_HOST_ROOT_PATH": str(root),
                                 "OPERATOR_HOST_ROOT_LOCK_MODE": "exclusive-held", **environment}
            code = ("import sys;sys.path.insert(0,sys.argv[1]);import operator_graph as g;"
                    "guard=g.DesignFlowRootGuard.open();assert guard is not None;"
                    "assert len(guard.binding_manifest)==96;guard.close()")
            child = subprocess.run(["/usr/bin/python3", "-E", "-s", "-c", code, str(graph_path.parent)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=child_environment, pass_fds=descriptors, timeout=30, check=False)
            assert child.returncode == 0, child.stderr
        finally:
            host._ACTIVE_HOST_ROOT = previous
            store.close()
    host.graph_module = original_graph
    host.parse_lanes = original_lanes


def mutation_postcommit_tests(host: Any) -> None:
    class Lock:
        def __init__(self, _path: Path, **_kwargs: Any): pass
        def __enter__(self) -> "Lock": return self
        def __exit__(self, *_args: Any) -> None: return None

    class PostGraph:
        MAX_JOURNAL_BYTES = 4 * 1024 * 1024
        MAX_GRAPH_BYTES = 4 * 1024 * 1024
        DirectoryLock = Lock
        @staticmethod
        def parse_committed_events(raw: bytes) -> list[Mapping[str, Any]]:
            assert raw and raw.endswith(b"\n")
            return [json.loads(line) for line in raw.splitlines()]
        @staticmethod
        def parse_json_bytes(raw: bytes, _path: Path, _code: str) -> Mapping[str, Any]:
            return json.loads(raw)
        @staticmethod
        def canonical_bytes(value: Any) -> bytes: return host.canonical(value)
        @staticmethod
        def validate_authority(value: Mapping[str, Any]) -> Mapping[str, Any]: return value
        @staticmethod
        def replay(events: list[Mapping[str, Any]], _authority: Mapping[str, Any]) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
            return events[-1]["definition"], events[-1]["projection"]

    original_graph = host.graph_module
    host.graph_module = lambda: PostGraph
    record = {"actorBindingId": "host-a", "holderScope": "scope:lane-a"}
    request = {"action": "transition", "graphId": "g", "nodeId": "task-a",
               "tickId": "tick", "requestId": "host-post-2", "expectedRevision": 1,
               "leaseId": "lease-1", "fence": 1, "targetState": "active", "ttlSeconds": None}
    result = {"ok": True, "command": "transition", "requestId": "host-post-2", "revision": 2,
              "data": {"nodeId": "task-a", "from": "ready", "to": "active"}}
    intent = {"nodeId": "task-a", "targetState": "active", "leaseId": "lease-1", "fence": 1}
    old_definition = {"schemaVersion": "fake", "revision": 1}
    old_projection = {"schemaVersion": "fake", "revision": 1}
    new_definition = {"schemaVersion": "fake", "revision": 2}
    new_projection = {"schemaVersion": "fake", "revision": 2}
    first = {"requestId": "host-post-1", "sequence": 1, "type": "graph.initialized",
             "intent": {}, "expectedRevision": None, "actor": {"bindingId": "host-a"},
             "result": {"ok": True}, "definition": old_definition, "projection": old_projection}
    second = {"requestId": request["requestId"], "sequence": 2, "type": "node.transitioned",
              "intent": intent, "expectedRevision": 1, "actor": {"bindingId": "host-a"},
              "result": result, "definition": new_definition, "projection": new_projection}
    before = host.canonical(first)
    after = before + host.canonical(second)

    def prepare() -> tuple[Path, Any, tempfile.TemporaryDirectory[str]]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name); root.chmod(0o700)
        (root / "authority").mkdir(mode=0o700)
        (root / "graph" / "bindings").mkdir(parents=True, mode=0o700)
        for path, data in ((root / "authority" / "control-graph-public-key.json", host.canonical({})),
                           (root / "graph" / "definition.json", host.canonical(old_definition)),
                           (root / "graph" / "projection.json", host.canonical(old_projection)),
                           (root / "graph" / "events.jsonl", before)):
            path.write_bytes(data); os.chmod(path, 0o600)
        store = host.AnchoredStore(root, acquire_exclusive=True, initialize_capability=True)
        return root, store, temporary

    def publish(root: Path) -> None:
        (root / "graph" / "events.jsonl").write_bytes(after)
        for name, value in (("definition.json", new_definition), ("projection.json", new_projection)):
            candidate = root / "graph" / (name + ".new")
            candidate.write_bytes(host.canonical(value)); os.chmod(candidate, 0o600)
            os.replace(candidate, root / "graph" / name)

    root, store, temporary = prepare(); prior = host._ACTIVE_HOST_ROOT; host._ACTIVE_HOST_ROOT = store
    try:
        publish(root)
        accepted = host.validate_refresh_host_mutation(record, request, host.canonical(result), before)
        assert accepted == result
        assert store.read_bytes(("graph", "definition.json"), host.MAX_JSON_BYTES) == host.canonical(new_definition)
    finally:
        host._ACTIVE_HOST_ROOT = prior; store.close(); temporary.cleanup()

    root, store, temporary = prepare(); prior = host._ACTIVE_HOST_ROOT; host._ACTIVE_HOST_ROOT = store
    try:
        old_definition_path = root / "graph" / "definition.old"
        old_projection_path = root / "graph" / "projection.old"
        (root / "graph" / "definition.json").rename(old_definition_path)
        (root / "graph" / "projection.json").rename(old_projection_path)
        publish(root)
        (root / "graph" / "definition.json").unlink(); old_definition_path.rename(root / "graph" / "definition.json")
        (root / "graph" / "projection.json").unlink(); old_projection_path.rename(root / "graph" / "projection.json")
        expect_error(host, "REPLAY_DRIFT", lambda: host.validate_refresh_host_mutation(
            record, request, host.canonical(result), before))
    finally:
        host._ACTIVE_HOST_ROOT = prior; store.close(); temporary.cleanup()

    root, store, temporary = prepare(); prior = host._ACTIVE_HOST_ROOT; host._ACTIVE_HOST_ROOT = store
    try:
        publish(root)
        journal_fd = store.file_fds[("graph", "events.jsonl")]
        os.ftruncate(journal_fd, 0); os.pwrite(journal_fd, before, 0); os.fsync(journal_fd)
        expect_error(host, "INTERFACE_PROTOCOL", lambda: host.validate_refresh_host_mutation(
            record, request, host.canonical(result), before))
    finally:
        host._ACTIVE_HOST_ROOT = prior; store.close(); temporary.cleanup()
    host.graph_module = original_graph


def effect_and_runner_tests(host: Any, record: Mapping[str, Any]) -> None:
    original = {name: getattr(host, name) for name in
                ("operator_dir", "load_session", "graph_snapshot", "locked_graph_snapshot",
                 "graph_module", "bounded_child")}
    graph = FakeGraph(host)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        host.operator_dir = lambda: root
        (root / "authority").mkdir(mode=0o700)
        (root / "graph" / "bindings").mkdir(parents=True, mode=0o700)
        (root / "authority" / "control-graph-public-key.json").write_bytes(b"{}\n")
        os.chmod(root / "authority" / "control-graph-public-key.json", 0o600)
        local_capability = host.command_root()
        previous_capability = host._ACTIVE_HOST_ROOT
        host._ACTIVE_HOST_ROOT = local_capability
        host.load_session = lambda *_args, **_kwargs: record
        host.graph_module = lambda: graph
        key = "sha256:" + hashlib.sha256((record["graphId"] + "\0" + record["nodeId"]).encode()).hexdigest()
        arguments = argparse.Namespace(tool=record["tool"], session=record["sessionId"], scope=record["nodeId"],
                                       idempotency_key=key, lease_id="lease-1", fence=1, name="effect.bin")

        shared = {"fence": 1}
        began = threading.Event()
        advanced = threading.Event()

        def preliminary() -> Mapping[str, Any]:
            began.set()
            assert advanced.wait(timeout=5)
            return lease_snapshot(host, record, shared["fence"], f"lease-{shared['fence']}")

        @contextlib.contextmanager
        def final_snapshot() -> Any:
            yield lease_snapshot(host, record, shared["fence"], f"lease-{shared['fence']}")

        host.graph_snapshot = preliminary
        host.locked_graph_snapshot = final_snapshot

        def advance_fence() -> None:
            assert began.wait(timeout=5)
            with host.host_commit_boundary():
                shared["fence"] = 2
            advanced.set()

        worker = threading.Thread(target=advance_fence)
        worker.start()
        saved_stdin = sys.stdin
        sys.stdin = SimpleNamespace(buffer=io.BytesIO(b"race"))
        try:
            expect_error(host, "FENCE_STALE", lambda: host.effect_commit(arguments))
        finally:
            sys.stdin = saved_stdin
        worker.join(timeout=5)
        assert not worker.is_alive()
        assert not list(root.rglob("*-effect.bin"))

        current = lease_snapshot(host, record)
        host.graph_snapshot = lambda: current

        @contextlib.contextmanager
        def current_locked() -> Any:
            yield current

        host.locked_graph_snapshot = current_locked

        def commit(payload: bytes) -> Mapping[str, Any]:
            saved = sys.stdin
            sys.stdin = SimpleNamespace(buffer=io.BytesIO(payload))
            try:
                return host.effect_commit(arguments)
            finally:
                sys.stdin = saved

        first = commit(b"same")
        retry = commit(b"same")
        assert first["retry"] is False and retry["retry"] is True
        expect_error(host, "EFFECT_CONFLICT", lambda: commit(b"changed"))
        expired = lease_snapshot(host, record, expired=True)
        host.graph_snapshot = lambda: expired
        expect_error(host, "LEASE_EXPIRED", lambda: commit(b"late"))
        wrong_lease = copy.copy(arguments)
        wrong_lease.lease_id = "lease-other"
        host.graph_snapshot = lambda: current
        expect_error(host, "FENCE_STALE", lambda: _commit_args(host, wrong_lease, b"wrong lease"))

        request = {
            "schemaVersion": host.RUN_REQUEST_VERSION, "tickId": "tick-1", "runId": "run-1",
            "idempotencyKey": key, "graphId": record["graphId"],
            "node": {"nodeId": record["nodeId"], "kind": "task", "title": "Hostile task",
                     "claims": {"files": ["scripts/owned"], "contracts": [], "resources": [],
                                "lanes": [record["laneNodeId"]]}},
            "lease": {"leaseId": "lease-1", "fence": 1, "expiresAt": "2099-01-01T00:00:00Z"},
        }
        host.graph_snapshot = lambda: current
        assert host.validate_runner_request(request, record) == request
        for mutate in (
            lambda value: value["node"].update(title="poisoned title"),
            lambda value: value["node"]["claims"]["files"].append("other"),
            lambda value: value["lease"].update(expiresAt="2098-01-01T00:00:00Z"),
        ):
            changed = copy.deepcopy(request)
            mutate(changed)
            try:
                host.validate_runner_request(changed, record)
            except host.HostError:
                pass
            else:
                raise AssertionError("runner snapshot mismatch was accepted")
        host.graph_snapshot = lambda: lease_snapshot(host, record, expired=True)
        expect_error(host, "LEASE_EXPIRED", lambda: host.validate_runner_request(request, record))

        worktree = root / "worktree"
        run_dir = root / "run"
        worktree.mkdir()
        run_dir.mkdir()
        environment = {"PATH": host.trusted_path(), "HOME": "/transport-home", "TMPDIR": str(run_dir),
                       "LC_ALL": "C", "LANG": "C"}

        def fake_codex(command: Any, _input: bytes, child_env: Mapping[str, str], cwd: Path,
                       _timeout: int, _maximum: int, pass_fds: Any = ()) -> tuple[int, bytes, bytes]:
            assert cwd == worktree and child_env == environment
            assert command[1:4] == ["-a", "never", "exec"]
            assert "-s" in command and command[command.index("-s") + 1] == "workspace-write"
            assert "-C" in command and command[command.index("-C") + 1] == str(worktree)
            assert "--ignore-user-config" in command and "--ignore-rules" in command and "--ephemeral" in command
            assert 'shell_environment_policy.inherit="none"' in command
            assert "--add-dir" in command and command[command.index("--add-dir") + 1] == str(run_dir)
            assert not host.FORBIDDEN_LAUNCH_TOKENS.intersection(command)
            os.write(pass_fds[1], host.canonical({"status": "succeeded", "summary": "restricted", "error": None}))
            return 0, b"", b""

        host.bounded_child = fake_codex
        codex_record = dict(record, tool="codex", runnerExecutable="/usr/bin/true")
        result = host.production_runner(codex_record, request, worktree, run_dir, environment)
        assert result["status"] == "succeeded" and result["fence"] == 1

        def fake_claude(command: Any, child_input: bytes, child_env: Mapping[str, str], cwd: Path,
                        _timeout: int, _maximum: int, pass_fds: Any = ()) -> tuple[int, bytes, bytes]:
            assert not child_input and not pass_fds and cwd == worktree and child_env == environment
            assert "--safe-mode" in command and "--permission-mode" in command
            assert command[command.index("--permission-mode") + 1] == "dontAsk"
            assert command[command.index("--tools") + 1] == "Read,Edit,Write,Glob,Grep"
            denied = command[command.index("--disallowedTools") + 1]
            assert all(name in denied.split(",") for name in ("Bash", "WebFetch", "WebSearch", "Task", "Agent", "Computer"))
            settings = json.loads(command[command.index("--settings") + 1])
            assert settings == {"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": False,
                                             "allowUnsandboxedCommands": False,
                                             "network": {"allowLocalBinding": False, "allowUnixSockets": []}}}
            assert not host.FORBIDDEN_LAUNCH_TOKENS.intersection(command)
            return 0, host.canonical({"structured_output": {
                "status": "succeeded", "summary": "restricted", "error": None}}), b""

        host.bounded_child = fake_claude
        claude_record = dict(record, tool="claude", runnerExecutable="/usr/bin/true")
        result = host.production_runner(claude_record, request, worktree, run_dir, environment)
        assert result["status"] == "succeeded" and result["leaseId"] == "lease-1"

        host._ACTIVE_HOST_ROOT = previous_capability
        local_capability.close()

    for name, value in original.items():
        setattr(host, name, value)


def _commit_args(host: Any, arguments: argparse.Namespace, payload: bytes) -> Mapping[str, Any]:
    saved = sys.stdin
    sys.stdin = SimpleNamespace(buffer=io.BytesIO(payload))
    try:
        return host.effect_commit(arguments)
    finally:
        sys.stdin = saved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--graph", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    args = parser.parse_args()
    host = load_host(args.host)
    record = json.loads(args.record.read_text())
    binding = json.loads(args.binding.read_text())
    path_tests(host)
    root = host.command_root()
    host._ACTIVE_HOST_ROOT = root
    try:
        broker_tests(host, record, binding)
    finally:
        host._ACTIVE_HOST_ROOT = None
        root.close()
    binding_manifest_stress_tests(host, args.graph, binding)
    mutation_postcommit_tests(host)
    effect_and_runner_tests(host, record)
    print("v5 host hostile in-process checks ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
